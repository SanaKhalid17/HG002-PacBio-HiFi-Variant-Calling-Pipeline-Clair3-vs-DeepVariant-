# HG002-PacBio-HiFi-Variant-Calling-Pipeline-Clair3-vs-DeepVariant-
This repository contains a reproducible, containerized variant calling and benchmarking pipeline for PacBio HiFi HG002 data on GRCh38. The workflow was designed to run on an HPC cluster using SLURM, executed via Singularity/Apptainer containers for modularity and scalability.


## Technologies Used

* **Workflow / Orchestration**

  * Nextflow (pipeline structure and modular design; DSL2 organization)
  * SLURM (job scheduling on HPC)

* **Containers**

  * Singularity / Apptainer
  * Tool containers used:

    * `minimap2.sif` (alignment)
    * `deepvariant.sif` (samtools, bcftools, DeepVariant)
    * `clair3.sif` (Clair3)
    * `happy.sif` (hap.py benchmarking)
  * The pipeline was also tested with the idea of an **all-in-one container** bundling these tools.

* **Bioinformatics Tools**

  * minimap2
  * samtools
  * bcftools
  * Clair3
  * DeepVariant
  * hap.py (vcfeval engine)

---

## Data

### Input Reads

* Sample: **HG002 (NA24385)**
* Platform: **PacBio HiFi**
* Subsampled dataset (¼ of original for this assignment):

```
data/HG002.quarter.fastq
```

### Reference Genome

* **GRCh38_no_alt_analysis_set.fasta**
* Indexed with samtools inside container

### Truth Set (GIAB v4.2.1, GRCh38, chr1–22)

* Truth VCF:

  ```
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz
  ```
* Confident regions BED:

  ```
  bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed
  ```

---

## Pipeline Structure

Conceptually, the pipeline is organized into the following stages (as in a DSL2 modular workflow):

1. **ALIGN**
   Input: FASTQ + Reference
   Output: Sorted, indexed BAM

2. **CALL_CLAIR3**
   Input: BAM + Reference
   Output: `clair3_out/merge_output.vcf.gz`

3. **CALL_DEEPVARIANT**
   Input: BAM + Reference
   Output: `HG002.deepvariant.vcf.gz`

4. **BENCHMARK_HAPPY**
   Input: VCF + Truth VCF + BED + Reference
   Output: `*_happy.summary.csv`, `*_happy.extended.csv`


## Container Runtime Setup

Because the cluster does not support `squashfuse`, containers are converted to sandboxes at runtime. Temporary directories are redirected to avoid `/tmp` space issues:

```bash
export APPTAINER_TMPDIR=$PWD/tmp_singularity
export SINGULARITY_TMPDIR=$PWD/tmp_singularity
export TMPDIR=$PWD/tmp_singularity
```

---

## Commands

### 1. Alignment (minimap2 → sorted BAM)

```bash
singularity exec containers/minimap2.sif minimap2 -t 8 -ax map-hifi \
  -R '@RG\tID:HG002\tSM:HG002\tPL:PACBIO' \
  ref/GRCh38_no_alt_analysis_set.fasta \
  data/HG002.quarter.fastq | \
singularity exec containers/deepvariant.sif samtools sort -@ 8 -o HG002.quarter.sorted.bam

singularity exec containers/deepvariant.sif samtools index HG002.quarter.sorted.bam
```

QC:

```bash
singularity exec containers/deepvariant.sif samtools flagstat HG002.quarter.sorted.bam > qc_flagstat.txt
```

---

### 2. DeepVariant (PACBIO model)

```bash
singularity exec containers/deepvariant.sif \
  /opt/deepvariant/bin/run_deepvariant \
    --model_type=PACBIO \
    --ref=ref/GRCh38_no_alt_analysis_set.fasta \
    --reads=HG002.quarter.sorted.bam \
    --output_vcf=HG002.deepvariant.vcf.gz \
    --num_shards=8

singularity exec containers/deepvariant.sif tabix -p vcf HG002.deepvariant.vcf.gz
```

---

### 3. Clair3 (HiFi model)

```bash
singularity exec containers/clair3.sif \
  /opt/bin/run_clair3.sh \
    -b HG002.quarter.sorted.bam \
    -f ref/GRCh38_no_alt_analysis_set.fasta \
    -m /opt/models/hifi \
    -p hifi \
    -t 8 \
    -o clair3_out
```

Output used:

```
clair3_out/merge_output.vcf.gz
```

---

### 4. Benchmarking with hap.py (GIAB)

Locale fix (Python 2.7 container):

```bash
export LANG=C
export LC_ALL=C
```

**Clair3:**

```bash
singularity exec containers/happy.sif /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  clair3_out/merge_output.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/clair3_happy \
  --engine=vcfeval \
  --threads=8
```

**DeepVariant:**

```bash
singularity exec containers/happy.sif /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  HG002.deepvariant.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/deepvariant_happy \
  --engine=vcfeval \
  --threads=8
```

---

### 5. Variant Counts and Per-Chromosome Statistics

Total counts:

```bash
column -t results/variant_counts.tsv
```

Output:

```
Caller        Total_variants   SNPs     INDELs
Clair3        90372            77448    12967
DeepVariant   115150           105567   9586
```

Per-chromosome:

```bash
singularity exec containers/deepvariant.sif bcftools view -H clair3_out/merge_output.vcf.gz | \
awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/clair3_per_chrom.tsv

singularity exec containers/deepvariant.sif bcftools view -H HG002.deepvariant.vcf.gz | \
awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/deepvariant_per_chrom.tsv
```

Merged table saved as:

```
per_chrom_variant_counts.tsv
```

---

## Results Summary

* Alignment:

  * Total reads: **55,188**
  * Mapped reads: **54,960 (99.59%)**
* Variant counts:

  * Clair3: **90,372 total** (77,448 SNPs, 12,967 INDELs)
  * DeepVariant: **115,150 total** (105,567 SNPs, 9,586 INDELs)
* Benchmarking:

  * hap.py summary CSVs available in:

    * `bench/results/clair3_happy.*`
    * `bench/results/deepvariant_happy.*`
  * Precision, Recall, F1 extracted into summary tables for the report.

## 🔹 Containerization

This project was implemented using **Singularity/Apptainer containerization** to ensure full reproducibility on the HPC cluster. Two complementary containerization approaches were used:

### 1) Tool-specific containers (modular execution)

Each major tool in the pipeline was executed inside its **official or pre-built container**:

* `minimap2.sif` → Read alignment
* `deepvariant.sif` → samtools, bcftools, DeepVariant
* `clair3.sif` → Clair3 variant caller
* `happy.sif` → hap.py benchmarking

These containers were orchestrated by the pipeline (Nextflow structure and SLURM batch scripts), ensuring:

* Reproducibility
* Isolation of dependencies
* Portability across HPC nodes

### 2) All-in-one pipeline container (custom-built)

In addition to using individual tool containers, we also **built a single all-in-one Singularity container** that bundles the complete pipeline environment, including:

* minimap2
* samtools / bcftools
* Clair3
* DeepVariant
* hap.py
* All required runtime dependencies

This custom container represents the **entire pipeline as a single portable artifact**, allowing the full workflow (alignment → variant calling → benchmarking → summarization) to be executed from one image.



## 🔹 SLURM + Nextflow Execution

```bash
#!/bin/bash
#SBATCH --job-name=hg002_allinone
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=24:00:00
#SBATCH --output=logs/allinone.%j.out
#SBATCH --error=logs/allinone.%j.err

cd ~/projects/HG002_assignment

export APPTAINER_TMPDIR=$PWD/tmp_singularity
export SINGULARITY_TMPDIR=$PWD/tmp_singularity
export TMPDIR=$PWD/tmp_singularity
mkdir -p "$TMPDIR"

singularity exec hg002_allinone.sif ./run_pipeline.sh \
  ref/GRCh38_no_alt_analysis_set.fasta \
  data/HG002.quarter.fastq \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  results_allinone
```

The entire workflow was containerized using Singularity/Apptainer: individual tool containers were used during development, and a custom all-in-one container was built to package the complete pipeline (alignment, Clair3, DeepVariant, and hap.py benchmarking) into a single reproducible image. The pipeline was executed on the HPC cluster using SLURM.
> 
## Reproducibility

* All tools are run in **containers**
* Pipeline is **SLURM-compatible**
* Full results are archived in:

```
HG002_assignment_results.tar.gz
``

