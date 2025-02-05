# PGS Batch

A command line tool for computing Polygenic Scores (PGS) from the PGS Catalog in batches using the `pgsc_calc` (v2.0.0) Nextflow pipeline.
This tool processes scoring files from the PGS Catalog's May 2024 release (n=4,735).

## Table of Contents
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage Guide](#usage-guide)
- [Working in Special Environments](#working-in-special-environments)
- [Troubleshooting](#troubleshooting)
- [Performance Considerations](#performance-considerations)

## Quick Start

```bash
# Clone and set up
git clone https://github.com/krillinor/pgs_batch.git
cd pgs_batch
export NXF_HOME="${PWD}/.nextflow"
curl -fsSL get.nextflow.io | bash

# Install dependencies
Rscript -e 'install.packages(c("docopt", "data.table", "fs", "readr", "curl", "stringr", "purrr"), repos = "http://cran.us.r-project.org")'

# Basic example
Rscript pgs_batch.R batch --n_per_batch=100
Rscript pgs_batch.R download --batch_id=1 --target_build=GRCh37
Rscript pgs_batch.R create_samplesheet --id=my_cohort --genos_path_prefix="/path/to/genotypes/prefix" --format=bfile
Rscript pgs_batch.R calc --id=my_cohort --target_build=GRCh37 --batch_id=1 --profile=docker
```

## Prerequisites

### Required Software
- Java v8 or higher
  - If experiencing Java issues: `export JAVA_HOME=/path/to/java` and `export NXF_JAVA_HOME=/path/to/java`, where `/path/to/java` is the parent folder containing `bin/java`
- [Nextflow](https://www.nextflow.io/)
- R version 4.2 or higher
- One of: Docker, Singularity, or Conda

## Installation

1. **Clone Repository**
   ```bash
   git clone https://github.com/krillinor/pgs_batch.git
   cd pgs_batch
   ```

2. **Install Nextflow**
   ```bash
   export NXF_HOME="${PWD}/.nextflow"
   curl -fsSL get.nextflow.io | bash
   ```

3. **Install R Dependencies**
   ```bash
   Rscript -e 'install.packages(c("docopt", "data.table", "fs", "readr", "curl", "stringr", "purrr"), repos = "http://cran.us.r-project.org")'
   ```

## Configuration

### Basic Configuration
Create the file `custom.config` to specify executor and adjust resource allocation.

Minimally, specify the executor. For example,

```nextflow
process {
    executor = 'local'
}
```

or

```nextflow
process {
    executor = 'slurm'
}
```

[See this `pgsc_calc` documentation for examples](https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html) and [this `nextflow` documentation for various executors](https://www.nextflow.io/docs/latest/executor.html).

How to change resource allocation ([base config](https://github.com/PGScatalog/pgsc_calc/blob/main/conf/base.config)):

```nextflow
process {
    executor = 'local'

    withLabel:process_low {
        cpus   = 2
        memory = 8.GB
        time   = 1.h
    }
    withLabel:process_medium {
        cpus   = 8
        memory = 64.GB
        time   = 4.h
    }
    withName: PLINK2_SCORE {
        maxForks = 4
    }
}
```

or for HPC, SLURM ([more here](https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html)):

```nextflow
process {
  errorStrategy = 'retry'
  maxRetries = 3
  maxErrors = '-1'
  executor = 'slurm'

  // etc.
}
```

(Note: `pgs_batch` has not been tested for cloud executors, but the `pgsc_calc` can work on [the cloud](https://pgsc-calc.readthedocs.io/en/latest/how-to/cloud.html)).

### Output Structure
```
project_root/
├── results/          # Final processing results
├── runs/             # Temporary processing files (can be deleted after completion)
├── batches/          # Batch definition files
└── scoringfiles/     # Downloaded scoring files
```

## Usage Guide

### 1. Create Batches

Split scoring files into manageable batches:
```bash
Rscript pgs_batch.R batch --n_batches=10  # Creates ~500 scores per batch
# OR
Rscript pgs_batch.R batch --n_per_batch=100  # Specify exact batch size
```

### 2. Download Scoring Files

Download files for each batch:
```bash
# Single batch
Rscript pgs_batch.R download --batch_id=1 --target_build=GRCh37

# All batches (using loop)
for i in {1..10}; do
    Rscript pgs_batch.R download --batch_id=${i} --target_build=GRCh37
done
```

### 3. Create Samplesheet

Generate input configuration:
```bash
Rscript pgs_batch.R create_samplesheet \
    --id=cohort_name \
    --genos_path_prefix="/path/to/genotypes/prefix" \
    --format=bfile
```

Use `--genos_single_file` if the genotype file is not split by chromosomes.

#### Samplesheet Format
The tool generates a CSV file (`samplesheet_cohort_name.csv`) containing:
- `sampleset`: Cohort identifier
- `path_prefix`: Path to genotype files
- `chrom`: Chromosome number (1-22)
- `format`: Genotype format (vcf/bfile/pfile)

### 5. Download ancestry files (optional)

```bash
Rscript pgs_batch.R get_ancestry_reference --1kg_hgdp
```

### 6. Run Analysis

Process each batch (remove `--ancestry` flag if ancestry-correction not needed):
```bash
# Single batch
Rscript pgs_batch.R calc \
    --id=cohort_name \
    --target_build=GRCh37 \
    --batch_id=1 \
    --profile=docker \
    --ancestry=full_path_to_file_from_step5

# All batches
for i in {1..10}; do
    Rscript pgs_batch.R calc \
        --id=cohort_name \
        --target_build=GRCh37 \
        --batch_id=${i} \
        --profile=docker \
        --ancestry=full_path_to_file_from_step5
done
```

## Working in Special Environments

### Offline Environment Setup

1. In an online environment:
   ```bash
   # Download scoring files
   Rscript pgs_batch.R download --batch_id=1 --target_build=GRCh37

   # Get pgsc_calc
   wget https://github.com/PGScatalog/pgsc_calc/archive/refs/tags/v2.0.0.zip
   unzip v2.0.0.zip

   # Install plugins
   export NXF_HOME="${PWD}/.nextflow"
   ./nextflow plugin install nf-validation@1.1.3
   ./nextflow plugin install nf-schema@2.0.0
   ./nextflow plugin install nf-prov@1.2.2
   ```

2. Download containers:
   ```bash
   cd pgsc_calc-2.0.0
   export NXF_SINGULARITY_CACHEDIR=nxf_sc
   mkdir -p $NXF_SINGULARITY_CACHEDIR
   
   # Get container list
   grep 'ext.singularity*' conf/modules.config | cut -f 2 -d '=' | \
       xargs -L 2 echo | tr -d ' ' > singularity_images.txt
   
   # Create paths
   cat singularity_images.txt | \
       sed 's/oras:\/\///;s/https:\/\///;s/\//-/g;s/$/.img/;s/:/-/' > \
       singularity_image_paths.txt
   
   # Download containers
   paste singularity_image_paths.txt singularity_images.txt | \
       while read -a line; do \
           singularity pull --disable-cache --dir $NXF_SINGULARITY_CACHEDIR \
           ${line[0]} ${line[1]}; \
       done
   ```

3. Transfer everything to offline environment
4. Run with offline flag:
   ```bash
   Rscript pgs_batch.R calc --offline ...
   ```

### HPC/Cluster Configuration

[See this `pgsc_calc` documentation for examples](https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html) and [this `nextflow` documentation for various executors](https://www.nextflow.io/docs/latest/executor.html).

## Troubleshooting

### Common Issues

1. **Java Problems**
   - Set Java environment variables:
     ```bash
     export JAVA_HOME=/path/to/java
     export NXF_JAVA_HOME=/path/to/java
     ```
     where `/path/to/java` is the parent folder containing `bin/java`.

2. **Memory Issues**
   - Adjust memory per process/label in `custom.config`. See [`pgsc_calc` documentation on memory/cpus](https://pgsc-calc.readthedocs.io/en/latest/how-to/bigjob.html) and [nextflow documentation on config files](https://www.nextflow.io/docs/latest/config.html)
   - the `--max_cpus=16` and `--max_memory=128.GB` are hard caps on available memory for any single process. Adjust if needed.
   - Use `--resume` flag to restart from last checkpoint

3. **Download Failures**
   - Use `--resume` with download command
   - Check network connectivity
   - Verify disk space

## Performance Considerations

- Storage: `runs` directory requires significant space
  - Clean up after successful completion
  - Keep final results in `results` directory
- Memory usage scales with batch size
- [Tips for HPC](https://seqera.io/blog/5_tips_for_hpc_users/) and [more tips for HPC](https://seqera.io/blog/5-more-tips-for-nextflow-user-on-hpc/)

## Future Improvements

- [ ] Results aggregation and QC metrics
- [ ] Automatic cleanup of runs subdirectories
- [ ] Parameter file support
