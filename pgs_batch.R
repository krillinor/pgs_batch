#!/usr/bin/env Rscript

# Load required packages
suppressPackageStartupMessages({
    library(docopt)
    library(stringr)
    library(fs)
    library(data.table)
    library(readr)
    library(curl)
    library(purrr)
})

# Constants
ALLOWED_TARGET_BUILDS <- c("GRCh37", "GRCh38")
ALLOWED_FORMATS <- c("vcf", "bfile", "pfile")
DEFAULT_TARGET_BUILD <- "GRCh38"
DEFAULT_PROFILE <- "singularity"
DEFAULT_NXF_VERSION <- "24.04.4"
DEFAULT_PGSC_CALC_VERSION <- "2.0.0"
DEFAULT_MAX_CPUS <- 32
DEFAULT_MAX_MEMORY <- "256.GB"
DEFAULT_MIN_OVERLAP <- 0

doc <- str_glue("
Usage:

  pgs_batch.R batch (--n_batches=<n_batches> | --n_per_batch=<n_per_batch>) [--dir=<dir> --force]
  pgs_batch.R download --batch_id=<batch_id> [--dir=<dir> --target_build=<target_build> --resume]
  pgs_batch.R create_samplesheet --id=<id> --genos_path_prefix=<genos_path_prefix> --format=<format> [--dir=<dir> --genos_single_file]
  pgs_batch.R calc --id=<id> --batch_id=<batch_id> [--dir=<dir> --profile=<profile> --target_build=<target_build> --min_overlap=<min_overlap> --ancestry=<ancestry> --max_cpus=<max_cpus> --max_memory=<max_memory> --resume --extra_args=<extra_args> --offline --singularity_bin=<singularity_bin> --nxf_ver=<nxf_ver> --pgsc_calc_version=<pgsc_calc_version> --nxf_cachedir=<nxf_cachedir>]
  pgs_batch.R get_ancestry_reference (--1kg | --1kg_hgdp) [--dir=<dir>]
  pgs_batch.R (-h | --help)
  pgs_batch.R --version

Options:
  -h --help
  --version
  --dir=<dir>                              Working directory. If null, then current.
  --id=<id>                                Analysis ID, f.x., name of cohort.
  --n_batches=<n_batches>                  Split scoring files into n_batches number of batches.
  --n_per_batch=<n_per_batch>              Split into batches that have n_per_batch scoring files.
  --force
  --batch_id=<batch_id>                    Run for specific batch.
  --target_build=<target_build>            Genome build [default: {DEFAULT_TARGET_BUILD}].
  --resume                                 Resume if something fails.
  --genos_path_prefix=<genos_path_prefix>  Genotype path prefix. Assumes one file per chromosome ending on the chromosome number. Otherwise, use genos_single_file flag (not recommended, slow)
  --format=<format>                        Genotype format: vcf, bfile (plink 1), or pfile (plink 2).
  --genos_single_file
  --profile=<profile>                      docker, singularity or conda [default: {DEFAULT_PROFILE}].
  --min_overlap=<min_overlap>              [default: {DEFAULT_MIN_OVERLAP}].
  --max_cpus=<max_cpus>                    [default: {DEFAULT_MAX_CPUS}].
  --max_memory=<max_memory>                [default: {DEFAULT_MAX_MEMORY}].
  --extra_args=<extra_args>                Specify arbitrary pgsc_calc parameters. Details: https://pgsc-calc.readthedocs.io/en/latest/reference/params.html.
  --offline                                Use if working in an offline environment. Make sure to download containers first (see docs).
  --ancestry=<ancestry>                    Run with continuous ancestry adjustment. Provide a full path to the reference file as argument, e.g. /path/to/pgsc_HGDP+1kGP_v1.tar.zst. Run get_ancestry_reference option to download reference files.
  --1kg                                    Download 1kg reference dataset in get_ancestry_reference
  --1kg_hgdp                               Download 1kg+hgdp reference dataset in get_ancestry_reference
  --singularity_bin=<singularity_bin>      Singularity binary.
  --nxf_ver=<nxf_ver>                      Nextflow version [default: {DEFAULT_NXF_VERSION}]
  --pgsc_calc_version=<pgsc_calc_version>  pgsc_calc version [default: {DEFAULT_PGSC_CALC_VERSION}]
  --nxf_cachedir=<nxf_cachedir>            Cache directory for nextflow.

")


#' Initialize directories and environment
#' @param args Parsed command line arguments
#' @return Modified args with initialized paths
initialize_environment <- function(args) {
    # Set working directory
    args$dir <- args$dir %||% getwd()

    # Create required directories
    dirs <- c("batches", "results", "runs", "scoringfiles")
    walk(dirs, ~ dir_create(file.path(args$dir, .x)))

    # Set up singularity if specified
    if (!is.null(args$singularity_bin)) {
        system2("alias", args = str_glue("singularity='{args$singularity_bin}'"))
    }

    # Configure nextflow environment
    args$nextflow <- str_glue("export NXF_VER=\"{args$nxf_ver %||% DEFAULT_NXF_VERSION}\"; {args$dir}/nextflow")
    args$pgsc_calc_version <- args$pgsc_calc_version %||% DEFAULT_PGSC_CALC_VERSION
    args$pgsc_calc <- str_glue("pgscatalog/pgsc_calc -r v{args$pgsc_calc_version}")

    # Set up cache directory
    args$cachedir <- args$nxf_cachedir %||% str_glue("{args$dir}/cache_{args$pgsc_calc_version}")
    if (!is.null(args$nxf_cachedir) && !dir_exists(args$nxf_cachedir)) {
        stop(str_glue("The cache directory {args$nxf_cachedir} does not exist."))
    }

    if (args$offline) {
        if (!dir_exists(str_glue("{args$dir}/pgsc_calc-{pgsc_calc_version}"))) {
            stop(str_glue("pgsc_calc-{pgsc_calc_version} directory doesn't exist. Follow the docs (under 'Offline')"))
        }
        # TODO check if nxf_sc exists
        system(str_glue("export NXF_SINGULARITY_CACHEDIR={args$dir}/pgsc_calc-{pgsc_calc_version}/nxf_sc"))
        args$pgsc_calc <- str_glue("{args$dir}/pgsc_calc-{pgsc_calc_version}/main.nf")
    } else {
        system(str_glue("export NXF_SINGULARITY_CACHEDIR={args$cachedir}"))
    }

    args
}


#' Process batches of PGS scoring files
#' @param args Command line arguments
#' @return NULL
run_batch <- function(args) {
    metadata <- fread(file.path(args$dir, "pgs_all_metadata_scores_20240510.csv"))
    pgs_ids <- metadata[[1]]
    dir_batches <- file.path(args$dir, "batches")

    # Check if batches directory needs clearing
    if (length(dir_ls(dir_batches)) > 0) {
        if (args$force) {
            dir_delete(dir_batches)
            dir_create(dir_batches)
        } else {
            stop(str_glue("Directory {dir_batches} not empty. Use --force to overwrite"))
        }
    }

    message(str_glue("Batching... Output directory: {dir_batches}"))

    # Create batches based on specified method
    batches <- if (!is.null(args$n_per_batch)) {
        split(pgs_ids, ceiling(seq_along(pgs_ids) / as.numeric(args$n_per_batch)))
    } else {
        split(pgs_ids, cut(seq_along(pgs_ids), as.numeric(args$n_batches), labels = FALSE))
    }

    # Write batch files
    iwalk(batches, ~ write_lines(.x, file.path(dir_batches, str_glue("batch{.y}"))))
}


#' Download PGS scoring files
#' @param args Command line arguments
#' @return NULL
run_download <- function(args) {
    if (!args$target_build %in% ALLOWED_TARGET_BUILDS) {
        stop(str_glue("Invalid target build. Must be one of: {paste(ALLOWED_TARGET_BUILDS, collapse = '/')}"))
    }

    dir_scoringfiles <- file.path(args$dir, "scoringfiles", str_glue("batch{args$batch_id}"))
    dir_create(dir_scoringfiles)

    batch <- read_lines(file.path(args$dir, "batches", str_glue("batch{args$batch_id}")))

    # Generate download paths and perform downloads
    pgs_paths <- str_glue("https://ftp.ebi.ac.uk/pub/databases/spot/pgs/scores/{batch}/ScoringFiles/Harmonized/{batch}_hmPOS_{args$target_build}.txt.gz")
    destfiles <- file.path(dir_scoringfiles, basename(pgs_paths))

    multi_download(pgs_paths, destfiles = destfiles, resume = args$resume)
}


#' Create sample sheet for analysis
#' @param args Command line arguments
#' @return NULL
create_samplesheet <- function(args) {
    if (!args$format %in% ALLOWED_FORMATS) {
        stop(str_glue("Invalid format. Must be one of: {paste(ALLOWED_FORMATS, collapse = '/')}"))
    }

    # Prepare sample sheet data
    if (args$genos_single_file) {
        samplesheet <- data.frame(
            sampleset = args$id,
            path_prefix = args$genos_path_prefix,
            chrom = NA,
            format = args$format
        )
    } else {
        samplesheet <- data.frame(
            sampleset = args$id,
            path_prefix = str_glue("{args$genos_path_prefix}{1:22}"),
            chrom = 1:22,
            format = args$format
        )
    }

    # Write sample sheet
    out_path <- file.path(args$dir, str_glue("samplesheet_{args$id}.csv"))
    message(str_glue("Writing sample sheet to {out_path}"))
    fwrite(samplesheet, out_path)
}


#' Download ancestry reference data
#' @param args Command line arguments
#' @return NULL
get_ancestry_reference <- function(args) {
    download_path <- if (args$`1kg`) {
        "https://ftp.ebi.ac.uk/pub/databases/spot/pgs/resources/pgsc_1000G_v1.tar.zst"
    } else if (args$`1kg_hgdp`) {
        "https://ftp.ebi.ac.uk/pub/databases/spot/pgs/resources/pgsc_HGDP+1kGP_v1.tar.zst"
    }

    message(str_glue("Downloading reference dataset: {download_path}"))
    destfile <- file.path(args$dir, basename(download_path))
    curl_download(url = download_path, destfile = destfile)
}


#' Run PGS calculation
#' @param args Command line arguments
#' @return NULL
run_calc <- function(args) {
    # Require custom.config file
    if (!file_exists(str_glue("{args$dir}/custom.config"))) {
        message(str_glue("You have to provide the file {args$dir}/custom.config where you specify the executor and allocated resources to run this pipeline.\nSee https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html for more details."))
    }

    # Validate ancestry reference if provided
    if (!is.null(args$ancestry) && !file_exists(args$ancestry)) {
        stop("Ancestry reference file does not exist")
    }

    # Prepare directories
    dir_runs <- file.path(args$dir, "runs", args$id, str_glue("batch{args$batch_id}"))
    dir_results <- file.path(args$dir, "results", args$id, str_glue("batch{args$batch_id}"))
    dir_create(dir_runs)

    # Build command components
    cmd_components <- list(
        ancestry = if (!is.null(args$ancestry)) str_glue(" --run_ancestry {args$ancestry}") else "",
        input = str_glue("{args$dir}/samplesheet_{args$id}.csv"),
        scores = str_glue("--scorefile \"{args$dir}/scoringfiles/batch{args$batch_id}/*{args$target_build}.txt.gz\""),
        config = str_glue(" -c {args$dir}/custom.config"),
        resume = if (args$resume) " -resume" else "",
        extra = if (!is.null(args$extra_args)) str_glue(" {args$extra_args}") else ""
    )

    # Set up offline mode if needed
    if (args$offline) {
        offline_setup <- c(
            str_glue("export NXF_OFFLINE='true'"),
            str_glue("export NXF_HOME={args$dir}/.nextflow"),
            str_glue("export NXF_SINGULARITY_CACHEDIR={args$dir}/pgsc_calc-{args$pgsc_calc_version}/nxf_sc")
        )
    }

    # Build and execute command
    cmd <- str_glue(
        "{if(args$offline) paste(offline_setup, collapse = '; ')}",
        "{args$nextflow} run {args$pgsc_calc}",
        "-profile {args$profile}",
        "--input {cmd_components$input}",
        "{cmd_components$scores}",
        "--target_build {args$target_build}",
        "--outdir {dir_results}",
        "--min_overlap {args$min_overlap %||% DEFAULT_MIN_OVERLAP}",
        "--fast_match --parallel",
        "--max_cpus {args$max_cpus %||% DEFAULT_MAX_CPUS}",
        "--max_memory {args$max_memory %||% DEFAULT_MAX_MEMORY}",
        "{cmd_components$config}",
        "{cmd_components$resume}",
        "{cmd_components$ancestry}",
        "{cmd_components$extra}"
    )

    # Execute command
    setwd(dir_runs)
    system2("cp", args = c("-R", file.path(args$dir, ".nextflow"), file.path(dir_runs, ".nextflow")))
    system(cmd)
}


# Main execution
main <- function() {
    args <- docopt(doc)
    args <- initialize_environment(args)

    # Execute requested command
    if (args$batch) run_batch(args)
    if (args$download) run_download(args)
    if (args$create_samplesheet) create_samplesheet(args)
    if (args$calc) run_calc(args)
    if (args$get_ancestry_reference) get_ancestry_reference(args)
}

if (!interactive()) {
    main()
}
