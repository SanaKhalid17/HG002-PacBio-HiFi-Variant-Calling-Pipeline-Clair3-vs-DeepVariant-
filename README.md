# HG002-PacBio-HiFi-Variant-Calling-Pipeline-Clair3-vs-DeepVariant-
This repository contains a reproducible, containerized variant calling and benchmarking pipeline for PacBio HiFi HG002 data on GRCh38. The workflow was designed to run on an HPC cluster using SLURM, executed via Singularity/Apptainer containers for modularity and scalability.
Technologies Used

Workflow / Orchestration

Nextflow (pipeline structure and modular design; DSL2-style organization)

SLURM (job scheduling on HPC)

Containers

Singularity / Apptainer

Tool containers used:

minimap2.sif (alignment)

deepvariant.sif (samtools, bcftools, DeepVariant)

clair3.sif (Clair3)

happy.sif (hap.py benchmarking)

The pipeline was also tested with the idea of an all-in-one container bundling these tools.

Bioinformatics Tools

minimap2

samtools

bcftools

Clair3

DeepVariant

hap.py (vcfeval engine)

Data
Input Reads

Sample: HG002 (NA24385)

Platform: PacBio HiFi

Subsampled dataset (¼ of original for this assignment):

data/HG002.quarter.fastq
Reference Genome

GRCh38_no_alt_analysis_set.fasta

Indexed with samtools inside container

Truth Set (GIAB v4.2.1, GRCh38, chr1–22)

Truth VCF:

bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz

Confident regions BED:

bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed
Pipeline Structure (Nextflow-style)

Conceptually, the pipeline is organized into the following stages (as in a DSL2 modular workflow):

ALIGN
Input: FASTQ + Reference
Output: Sorted, indexed BAM

CALL_CLAIR3
Input: BAM + Reference
Output: clair3_out/merge_output.vcf.gz

CALL_DEEPVARIANT
Input: BAM + Reference
Output: HG002.deepvariant.vcf.gz

BENCHMARK_HAPPY
Input: VCF + Truth VCF + BED + Reference
Output: *_happy.summary.csv, *_happy.extended.csv

SUMMARIZE_RESULTS
Output:

Total variant counts table

Per-chromosome variant counts table

QC tables from alignment

Even though many steps were run manually for debugging, the structure follows a Nextflow pipeline design and was also tested under SLURM batch submission.

SLURM Execution

The pipeline was tested using SLURM, for example:

sbatch align.slurm
squeue -u $USER

This confirms the workflow can be executed in batch mode on compute nodes, not only interactively.

Container Runtime Setup

Because the cluster does not support squashfuse, containers are converted to sandboxes at runtime. Temporary directories are redirected to avoid /tmp space issues:

export APPTAINER_TMPDIR=$PWD/tmp_singularity
export SINGULARITY_TMPDIR=$PWD/tmp_singularity
export TMPDIR=$PWD/tmp_singularity
Step-by-Step Commands
1. Alignment (minimap2 → sorted BAM)
singularity exec containers/minimap2.sif minimap2 -t 8 -ax map-hifi \
  -R '@RG\tID:HG002\tSM:HG002\tPL:PACBIO' \
  ref/GRCh38_no_alt_analysis_set.fasta \
  data/HG002.quarter.fastq | \
singularity exec containers/deepvariant.sif samtools sort -@ 8 -o HG002.quarter.sorted.bam

singularity exec containers/deepvariant.sif samtools index HG002.quarter.sorted.bam

QC:

singularity exec containers/deepvariant.sif samtools flagstat HG002.quarter.sorted.bam > qc_flagstat.txt
2. DeepVariant (PACBIO model)
singularity exec containers/deepvariant.sif \
  /opt/deepvariant/bin/run_deepvariant \
    --model_type=PACBIO \
    --ref=ref/GRCh38_no_alt_analysis_set.fasta \
    --reads=HG002.quarter.sorted.bam \
    --output_vcf=HG002.deepvariant.vcf.gz \
    --num_shards=8

singularity exec containers/deepvariant.sif tabix -p vcf HG002.deepvariant.vcf.gz
3. Clair3 (HiFi model)
singularity exec containers/clair3.sif \
  /opt/bin/run_clair3.sh \
    -b HG002.quarter.sorted.bam \
    -f ref/GRCh38_no_alt_analysis_set.fasta \
    -m /opt/models/hifi \
    -p hifi \
    -t 8 \
    -o clair3_out

Output used:

clair3_out/merge_output.vcf.gz
4. Benchmarking with hap.py (GIAB)

Locale fix (Python 2.7 container):

export LANG=C
export LC_ALL=C

Clair3:

singularity exec containers/happy.sif /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  clair3_out/merge_output.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/clair3_happy \
  --engine=vcfeval \
  --threads=8

DeepVariant:

singularity exec containers/happy.sif /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  HG002.deepvariant.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/deepvariant_happy \
  --engine=vcfeval \
  --threads=8
5. Variant Counts and Per-Chromosome Statistics

Total counts:

column -t results/variant_counts.tsv

Output:

Caller        Total_variants   SNPs     INDELs
Clair3        90372            77448    12967
DeepVariant   115150           105567   9586

Per-chromosome:

singularity exec containers/deepvariant.sif bcftools view -H clair3_out/merge_output.vcf.gz | \
awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/clair3_per_chrom.tsv

singularity exec containers/deepvariant.sif bcftools view -H HG002.deepvariant.vcf.gz | \
awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/deepvariant_per_chrom.tsv

Merged table saved as:

per_chrom_variant_counts.tsv
Results Summary

Alignment:

Total reads: 55,188

Mapped reads: 54,960 (99.59%)

Variant counts:

Clair3: 90,372 total (77,448 SNPs, 12,967 INDELs)

DeepVariant: 115,150 total (105,567 SNPs, 9,586 INDELs)

Benchmarking:

hap.py summary CSVs available in:

bench/results/clair3_happy.*

bench/results/deepvariant_happy.*

Precision, Recall, F1 extracted into summary tables for the report.

Because only ¼ of the reads were used, recall is low for both callers, which explains the low F1-scores.

Reproducibility

All tools are run in containers

Pipeline is SLURM-compatible

Workflow is structured in a Nextflow-style modular design

Full results are archived in:

HG002_assignment_results.tar.gz
Conclusion

This project implements a full, HPC-ready, containerized variant calling and benchmarking pipeline using Nextflow-style workflow design, SLURM scheduling, and Singularity containers, comparing Clair3 and DeepVariant on PacBio HiFi HG002 data against the GIAB v4.2.1 truth set.
