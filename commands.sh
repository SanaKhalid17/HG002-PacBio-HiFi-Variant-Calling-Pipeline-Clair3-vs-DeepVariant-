#!/usr/bin/env bash
set -euo pipefail

# HG002 assignment command log (HPC)
# Host used in this run: 10.19.10.150
# User: sana.sines
# Project: ~/projects/HG002_assignment

########################################
# 0) Project setup
########################################
mkdir -p ~/projects/HG002_assignment/{data,ref,results,work,containers,bench,logs,nextflow}
mkdir -p ~/projects/HG002_assignment/results/{alignment,deepvariant,clair3}
mkdir -p ~/projects/HG002_assignment/bench/{truth,results}
cd ~/projects/HG002_assignment

########################################
# 1) Container temp dirs (avoid /tmp issues)
########################################
mkdir -p tmp_singularity
export APPTAINER_TMPDIR=$PWD/tmp_singularity
export SINGULARITY_TMPDIR=$PWD/tmp_singularity
export TMPDIR=$PWD/tmp_singularity

########################################
# 2) Reference preparation (GRCh38)
########################################
# Reference fasta expected at: ref/GRCh38_no_alt_analysis_set.fasta
# Index reference (samtools inside deepvariant.sif)
singularity exec containers/deepvariant.sif samtools faidx ref/GRCh38_no_alt_analysis_set.fasta

########################################
# 3) Align reads (minimap2) -> sorted BAM (samtools)
########################################
# Query FASTQ expected at: data/HG002.quarter.fastq
singularity exec containers/minimap2.sif minimap2 -t 8 -ax map-hifi \
  -R '@RG\tID:HG002\tSM:HG002\tPL:PACBIO' \
  ref/GRCh38_no_alt_analysis_set.fasta \
  data/HG002.quarter.fastq | \
singularity exec containers/deepvariant.sif samtools sort -@ 8 -o HG002.quarter.sorted.bam

singularity exec containers/deepvariant.sif samtools index HG002.quarter.sorted.bam
singularity exec containers/deepvariant.sif samtools flagstat HG002.quarter.sorted.bam > results/alignment/alignment_flagstat.txt
mv HG002.quarter.sorted.bam* results/alignment/

########################################
# 4) Variant calling: DeepVariant (PACBIO)
########################################
singularity exec containers/deepvariant.sif \
  /opt/deepvariant/bin/run_deepvariant \
    --model_type=PACBIO \
    --ref=ref/GRCh38_no_alt_analysis_set.fasta \
    --reads=results/alignment/HG002.quarter.sorted.bam \
    --output_vcf=HG002.deepvariant.vcf.gz \
    --num_shards=8

singularity exec containers/deepvariant.sif tabix -p vcf HG002.deepvariant.vcf.gz
mv HG002.deepvariant.vcf.gz* results/deepvariant/

########################################
# 5) Variant calling: Clair3 (HiFi model)
########################################
singularity exec containers/clair3.sif \
  /opt/bin/run_clair3.sh \
    -b results/alignment/HG002.quarter.sorted.bam \
    -f ref/GRCh38_no_alt_analysis_set.fasta \
    -m /opt/models/hifi \
    -p hifi \
    -t 8 \
    -o clair3_out

# Optional copy into results tree
cp clair3_out/merge_output.vcf.gz results/clair3/HG002.clair3.vcf.gz
cp clair3_out/merge_output.vcf.gz.tbi results/clair3/HG002.clair3.vcf.gz.tbi

########################################
# 6) Download GIAB truth set (HTTPS)
########################################
cd bench/truth
wget https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz
wget https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi
curl -L -O https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed
cd ../../

########################################
# 7) Benchmark with hap.py (locale fix + full path)
########################################
export LANG=C
export LC_ALL=C

# Clair3
singularity exec containers/happy.sif \
  /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  clair3_out/merge_output.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/clair3_happy \
  --engine=vcfeval \
  --threads=8

# DeepVariant
singularity exec containers/happy.sif \
  /opt/hap.py/bin/hap.py \
  bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  results/deepvariant/HG002.deepvariant.vcf.gz \
  -f bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  -r ref/GRCh38_no_alt_analysis_set.fasta \
  -o bench/results/deepvariant_happy \
  --engine=vcfeval \
  --threads=8

########################################
# 8) Tables for README/report
########################################
# Variant totals
singularity exec containers/deepvariant.sif bcftools view -H clair3_out/merge_output.vcf.gz | wc -l
singularity exec containers/deepvariant.sif bcftools view -H -v snps clair3_out/merge_output.vcf.gz | wc -l
singularity exec containers/deepvariant.sif bcftools view -H -v indels clair3_out/merge_output.vcf.gz | wc -l

singularity exec containers/deepvariant.sif bcftools view -H results/deepvariant/HG002.deepvariant.vcf.gz | wc -l
singularity exec containers/deepvariant.sif bcftools view -H -v snps results/deepvariant/HG002.deepvariant.vcf.gz | wc -l
singularity exec containers/deepvariant.sif bcftools view -H -v indels results/deepvariant/HG002.deepvariant.vcf.gz | wc -l

# Per-chrom counts
singularity exec containers/deepvariant.sif bcftools view -H clair3_out/merge_output.vcf.gz | awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/clair3_per_chrom.tsv
singularity exec containers/deepvariant.sif bcftools view -H results/deepvariant/HG002.deepvariant.vcf.gz | awk '{print $1}' | sort | uniq -c | awk '{print $2"\t"$1}' > results/deepvariant_per_chrom.tsv

########################################
# 9) Export results tarball for local download
########################################
cd ~/projects/HG002_assignment
mkdir -p export_package
cp -r results export_package/
cp -r bench/results export_package/bench_results
cp -r clair3_out export_package/clair3_out
cp -r bench/truth export_package/bench_truth
tar -czf HG002_assignment_results.tar.gz export_package

# On local Mac:
# scp sana.sines@10.19.10.150:/hdd4/sines/advancedcomputationalbiology/sana.sines/projects/HG002_assignment/HG002_assignment_results.tar.gz .
# tar -xzf HG002_assignment_results.tar.gz
