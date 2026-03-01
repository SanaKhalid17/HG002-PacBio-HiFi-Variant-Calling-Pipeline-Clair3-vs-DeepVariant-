# HG002-PacBio-HiFi-Variant-Calling-Pipeline
This repository contains a reproducible, containerized variant calling and benchmarking pipeline for PacBio HiFi HG002 data on GRCh38. The workflow was designed to run on an HPC cluster using SLURM, executed via Singularity/Apptainer containers for modularity and scalability.

![Nextflow](https://img.shields.io/badge/Nextflow-DSL2-23aa62)
![SLURM](https://img.shields.io/badge/SLURM-HPC-blue)
![Singularity](https://img.shields.io/badge/Singularity-Apptainer-1f6feb)
![Minimap2](https://img.shields.io/badge/Minimap2-2.28-orange)
![Samtools](https://img.shields.io/badge/Samtools-1.20-red)
![Clair3](https://img.shields.io/badge/Clair3-HiFi-green)
![DeepVariant](https://img.shields.io/badge/DeepVariant-1.6.1-ff9800)
![hap.py](https://img.shields.io/badge/hap.py-vcfeval-purple)

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

## Nextflow Workflow Implementation

This variant calling pipeline was implemented using **Nextflow DSL2** to enable modular, containerized, and reproducible execution on HPC infrastructure.

### Main Execution Command

Local execution:

```bash
nextflow run main.nf
```

SLURM execution (recommended on cluster):

```bash
sbatch run_nf.slurm
```

The SLURM script internally runs:

```bash
nextflow run main.nf -profile slurm \
  --reference ref/GRCh38_no_alt_analysis_set.fasta \
  --reads data/HG002.quarter.fastq \
  --truth_vcf bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  --truth_bed bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  --sample HG002 \
  --threads 8
```

---

## Workflow Steps

1. **ALIGN_READS**

   * Align PacBio HiFi reads to GRCh38 using minimap2
   * Sort and index BAM using samtools

2. **CALL_DEEPVARIANT**

   * Variant calling using DeepVariant (PACBIO model)

3. **CALL_CLAIR3**

   * Variant calling using Clair3 (HiFi mode)

4. **HAPPY_CLAIR3**

   * Benchmark Clair3 output using hap.py (vcfeval engine)

5. **HAPPY_DEEPVARIANT**

   * Benchmark DeepVariant output using hap.py (vcfeval engine)

All tools were executed via Singularity containers to ensure reproducibility.

---

## Execution Summary

* Runtime: **48 minutes 38 seconds**
* CPU usage: **7.6 CPU hours**
* Executor: Local (SLURM profile available)
* Status: **Succeeded (5/5 processes)**

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


## Results

### Total Variant Counts

From the final VCF files:

| Caller      | Total Variants | SNPs    | INDELs |
| ----------- | -------------- | ------- | ------ |
| Clair3      | 90,372         | 77,448  | 12,967 |
| DeepVariant | 115,150        | 105,567 | 9,586  |

DeepVariant reports more total variants and substantially more SNPs, while Clair3 reports more INDELs in this reduced-coverage dataset.

---

### Benchmarking Results (GIAB v4.2.1, PASS variants, chr1–22)

Values extracted from `clair3_happy.extended.csv` and `deepvariant_happy.extended.csv`.

| Caller      | Variant | Filter | Precision | Recall   | F1-score |
| ----------- | ------- | ------ | --------- | -------- | -------- |
| Clair3      | SNP     | PASS   | 0.819215  | 0.010620 | 0.020968 |
| Clair3      | INDEL   | PASS   | 0.661303  | 0.005754 | 0.011409 |
| DeepVariant | SNP     | PASS   | 0.727231  | 0.005983 | 0.011869 |
| DeepVariant | INDEL   | PASS   | 0.656781  | 0.003650 | 0.007259 |


* Precision is moderate to high for both callers, especially for SNPs.
* Recall is very low for both callers because only **¼ of the reads** were used, leading to low effective coverage.
* Consequently, F1-scores are also low.
* In a full-coverage dataset, DeepVariant is expected to significantly outperform in recall and F1, as shown in published benchmarks.

---

### Per-chromosome Variant Counts (excerpt)

| Chromosome | Clair3 | DeepVariant |
| ---------- | ------ | ----------- |
| chr1       | 6,860  | 29,632      |
| chr2       | 6,236  | 4,234       |
| chr3       | 5,185  | 4,725       |
| chr4       | 7,293  | 8,262       |
| chr5       | 4,443  | 4,309       |
| chr6       | 4,361  | 4,534       |
| chr7       | 4,175  | 2,628       |
| chr8       | 3,996  | 3,304       |
| chr9       | 3,669  | 3,619       |
| chr10      | 6,130  | 6,469       |
| chr11      | 2,945  | 2,585       |
| chr12      | 3,177  | 2,330       |
| …          | …      | …           |

Both callers show broadly similar chromosomal distributions, with DeepVariant generally producing higher counts, particularly on larger chromosomes.

---

## Benchmarking Results (DeepVariant vs GIAB HG002 v4.2.1)

| Variant Type | Truth Total | True Positives | False Negatives | Query Total | False Positives | Query Unknown | Genotype FP |
| ------------ | ----------- | -------------- | --------------- | ----------- | --------------- | ------------- | ----------- |
| SNP          | 3,460,128   | 20,703         | 3,439,425       | 46,301      | 7,769           | 17,819        | 7,736       |
| INDEL        | 586,877     | 2,142          | 584,735         | 5,356       | 1,111           | 2,119         | 1,026       |

---

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

