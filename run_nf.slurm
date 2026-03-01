#!/bin/bash
#SBATCH --job-name=hg002_nf
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=24:00:00
#SBATCH --output=logs/nextflow.%j.out
#SBATCH --error=logs/nextflow.%j.err

set -euo pipefail

cd ~/projects/HG002_assignment

mkdir -p logs work tmp_singularity results/alignment results/deepvariant results/clair3 bench/results
export NXF_HOME=$PWD/.nextflow

module load nextflow 2>/dev/null || true
module load singularity 2>/dev/null || true

nextflow run main.nf -profile slurm \
  --use_local_sifs true \
  --sif_minimap2 containers/minimap2.sif \
  --sif_deepvariant containers/deepvariant.sif \
  --sif_clair3 containers/clair3.sif \
  --sif_happy containers/happy.sif \
  --reference ref/GRCh38_no_alt_analysis_set.fasta \
  --reads data/HG002.quarter.fastq \
  --model_path /opt/models/hifi \
  --truth_vcf bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  --truth_bed bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed \
  --sample HG002 \
  --threads 8
