# pgs_batch

A script to run PGS from the PGS Catalog in batches using the `nextflow` pipeline `pgsc_calc` (v2.0.0).
Uses scoring files from the PGS Catalog downloaded on 2024/05/10 (n=4735).

## Dependencies
- java v8+
	- If having trouble with java when running the scripts below, export these variables `export JAVA_HOME=/path/to/java` and `export NXF_JAVA_HOME=/path/to/java`, where `/path/to/java` is the directory that contains `bin/java`
- nextflow
- R>=4.2 and Rscript

## Setup

```bash
git clone https://github.com/krillinor/pgs_batch.git
cd pgs_batch
# install nextflow
export NXF_HOME=${PWD}/.nextflow
curl -fsSL get.nextflow.io | bash
# install R packages
Rscript -e 'install.packages(c("docopt", "data.table", "fs", "readr", "curl", "stringr", "purrr"), repos = "http://cran.us.r-project.org")'
```

## Config file

Change memory/cpus/max_forks in the `custom.config` file (details on nextflow/pgsc_calc config [here](https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html#how-do-i-run-pgsc-calc-on-larger-datasets-and-more-powerful-computers)).

## Output

Results will appear in the `results` directory.
Takes ~1hr to run for 500 PGS (1/10 batches) with the default config file.
The `runs` directory is temporary and takes a lot of space. Best to remove subdirectories in `runs` after PGS have been computed.

## Example

### Step 1: Specify number of batches

Create batches based on available scoring files on 2024/05/10 (n=4735).
For example, 10 batches (~500 per file).

```bash
Rscript pgs_batch.R batch --n_batches=10
```

### Step 2: Download scoring files

Download scoring files for each batch.
Specifying the correct build for the target cohort is important (GRCh37/GRCh38).
Use `--resume` if the download fails.

```bash
for i in {1..10}; do
    Rscript pgs_batch.R download --batch_id=${i} --target_build=GRCh37
done
```

### Step 3: Create the samplesheet

Specify the inputs.
You need to provide the cohort name with `--id` (replace "cohort_name" with the name of your cohort, f.x., "UKB"), the prefix to the genotypes with `--genos_path_prefix`, and the genotype format (vcf/bfile/pfile) with `--format`. Assumes one file per chromosome. If there's a single genotype file, use `--genos_single_file`.
More details [here](https://pgsc-calc.readthedocs.io/en/latest/how-to/samplesheet.html#setup-samplesheet).

```bash
Rscript pgs_batch.R create_samplesheet --id=cohort_name --genos_path_prefix="/path/to/genotypes/prefix" --format=bfile
```

Creates the file `samplesheet_cohort_name.csv`:

```
sampleset,path_prefix,chrom,format
cohort_name,/path/to/genotypes/prefix1,1,bfile
cohort_name,/path/to/genotypes/prefix2,2,bfile
cohort_name,/path/to/genotypes/prefix3,3,bfile
cohort_name,/path/to/genotypes/prefix4,4,bfile
cohort_name,/path/to/genotypes/prefix5,5,bfile
cohort_name,/path/to/genotypes/prefix6,6,bfile
cohort_name,/path/to/genotypes/prefix7,7,bfile
cohort_name,/path/to/genotypes/prefix8,8,bfile
cohort_name,/path/to/genotypes/prefix9,9,bfile
cohort_name,/path/to/genotypes/prefix10,10,bfile
cohort_name,/path/to/genotypes/prefix11,11,bfile
cohort_name,/path/to/genotypes/prefix12,12,bfile
cohort_name,/path/to/genotypes/prefix13,13,bfile
cohort_name,/path/to/genotypes/prefix14,14,bfile
cohort_name,/path/to/genotypes/prefix15,15,bfile
cohort_name,/path/to/genotypes/prefix16,16,bfile
cohort_name,/path/to/genotypes/prefix17,17,bfile
cohort_name,/path/to/genotypes/prefix18,18,bfile
cohort_name,/path/to/genotypes/prefix19,19,bfile
cohort_name,/path/to/genotypes/prefix20,20,bfile
cohort_name,/path/to/genotypes/prefix21,21,bfile
cohort_name,/path/to/genotypes/prefix22,22,bfile
```

### Step 4: Run pgsc_calc for each batch

Run sequentially for each batch (or submit to cluster).
Specifying the correct build for the target cohort is important (GRCh37/GRCh38).
Specify docker/singularity/conda with `--profile` based on availability.
Modify the `custom.config` file to use more/less resources (f.x., if killed because of too little memory).
Use `--resume` to resume the pipeline from the last completed step (f.x., if it failed somewhere because of too little memory).
Use `--extra_args` to specify additional parameters, f.x., `--extra_args="  --keep_ambiguous"` to keep ambiguous variants (not recommended) in the matching step (`pgsc_calc` automatically filters them out).

```bash
for i in {1..10}; do
    Rscript pgs_batch.R calc --id=cohort_name --target_build=GRCh37 --batch_id=${i} --profile=docker
done
```

## Offline environment

If working in an offline environment, run the following steps in an online environment before transferring to the offline environment.

1. Download all scoring files (see Step 2 in the example below).
2. Download `pgsc_calc` and plugins:

```bash
# download pgsc_calc and unzip
wget https://github.com/PGScatalog/pgsc_calc/archive/refs/tags/v2.0.0.zip
unzip v2.0.0.zip

export NXF_HOME="${PWD}/.nextflow"
./nextflow plugin install nf-validation@1.1.3
./nextflow plugin install nf-schema@2.0.0
./nextflow plugin install nf-prov@1.2.2
```

3. Download `singularity` containers (also possible for [docker](https://pgsc-calc.readthedocs.io/en/latest/how-to/offline.html#docker)):

```bash
cd pgsc_calc-2.0.0
NXF_SINGULARITY_CACHEDIR=nxf_sc
mkdir -p $NXF_SINGULARITY_CACHEDIR
grep 'ext.singularity*' conf/modules.config | cut -f 2 -d '=' | xargs -L 2 echo | tr -d ' ' > singularity_images.txt
cat singularity_images.txt | sed 's/oras:\/\///;s/https:\/\///;s/\//-/g;s/$/.img/;s/:/-/' > singularity_image_paths.txt
paste singularity_image_paths.txt singularity_images.txt | while read -a line; do singularity pull --disable-cache --dir $NXF_SINGULARITY_CACHEDIR ${line[0]} ${line[1]}; done
```

4. Move everything (the pgs_batch directory) to the offline environment.
5. Use `--offline` when running `Rscript pgs_batch.R calc`.

## Computing cluster

If using a computing cluster, specify the details in `custom.config` (example for `slurm`):

```
process {
    executor = 'slurm'
    queue    = 'cpu-short'

    withLabel:process_low {
        cpus   = 2
        memory = 8.GB
        time    = 1.h
    }
    withLabel:process_medium {
        cpus     = 4
        memory   = 16.GB
        maxForks = 4
        time     = 4.h
    }
    withName: PLINK2_SCORE {
        maxForks = 22
    }
}

executor {
    name = 'slurm'
    queueSize = 22
    submitRateLimit = '10 sec'
}
```

Also, export these variables in the `sbatch` script:

```
export NXF_ANSI_LOG=false
export NXF_OPTS="-Xms1G -Xmx4G"
```

## TODOs

- arg checks
- combine results + QC metrics
- delete runs subdirs on completion unless flag
- add install_singularity.sh script
- use params file
