nextflow.enable.dsl=2

params.reference   = "ref/GRCh38_no_alt_analysis_set.fasta"
params.reads       = "data/HG002.quarter.fastq"
params.sample      = "HG002"

params.model_type  = "PACBIO"
params.model_path  = "/opt/models/hifi"

params.truth_vcf   = "bench/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
params.truth_bed   = "bench/truth/HG002_GRCh38_1_22_v4.2.1_confident_regions.bed"

params.threads     = 8

params.sif_minimap2    = "/hdd4/sines/advancedcomputationalbiology/sana.sines/projects/HG002_assignment/containers/minimap2.sif"
params.sif_deepvariant = "/hdd4/sines/advancedcomputationalbiology/sana.sines/projects/HG002_assignment/containers/deepvariant.sif"
params.sif_clair3      = "/hdd4/sines/advancedcomputationalbiology/sana.sines/projects/HG002_assignment/containers/clair3.sif"
params.sif_happy       = "/hdd4/sines/advancedcomputationalbiology/sana.sines/projects/HG002_assignment/containers/happy.sif"

workflow {

    reads_ch  = Channel.fromPath(params.reads, checkIfExists: true)
    ref_ch    = Channel.fromPath(params.reference, checkIfExists: true)
    fai_ch    = Channel.fromPath("${params.reference}.fai", checkIfExists: true)

    truth_vcf_ch = Channel.fromPath(params.truth_vcf, checkIfExists: true)
    truth_bed_ch = Channel.fromPath(params.truth_bed, checkIfExists: true)

    // ALIGN
    align_input = reads_ch.combine(ref_ch)
    bam_tuple_ch = ALIGN_READS(align_input)

    // DEEPVARIANT
    dv_input = bam_tuple_ch
        .combine(ref_ch)
        .combine(fai_ch)
        .map { bam, bai, reference, fai ->
            tuple(bam, bai, reference, fai)
        }

    deep_vcf_ch = CALL_DEEPVARIANT(dv_input)

    // CLAIR3
    clair_input = bam_tuple_ch
        .map { bam, bai -> bam }
        .combine(ref_ch)
        .map { bam, reference ->
            tuple(bam, reference)
        }

    clair_vcf_ch = CALL_CLAIR3(clair_input)

    // HAP.PY CLAIR3 (NOW INCLUDING FAI)
    happy_clair_input = truth_vcf_ch
        .combine(clair_vcf_ch)
        .combine(truth_bed_ch)
        .combine(ref_ch)
        .combine(fai_ch)
        .map { truth, query, bed, reference, fai ->
            tuple(truth, query, bed, reference, fai)
        }

    HAPPY_CLAIR3(happy_clair_input)

    // HAP.PY DEEPVARIANT (NOW INCLUDING FAI)
    happy_dv_input = truth_vcf_ch
        .combine(deep_vcf_ch)
        .combine(truth_bed_ch)
        .combine(ref_ch)
        .combine(fai_ch)
        .map { truth, query, bed, reference, fai ->
            tuple(truth, query, bed, reference, fai)
        }

    HAPPY_DEEPVARIANT(happy_dv_input)
}

process ALIGN_READS {

    cpus params.threads
    publishDir "results/alignment", mode: 'copy'

    input:
        tuple path(reads), path(reference)

    output:
        tuple path("${params.sample}.sorted.bam"),
              path("${params.sample}.sorted.bam.bai")

    script:
    """
    singularity exec ${params.sif_minimap2} minimap2 \
        -t ${task.cpus} \
        -ax map-hifi \
        -R '@RG\\tID=${params.sample}\\tSM=${params.sample}\\tPL=PACBIO' \
        ${reference} ${reads} | \
    singularity exec ${params.sif_deepvariant} samtools sort \
        -@ ${task.cpus} \
        -o ${params.sample}.sorted.bam

    singularity exec ${params.sif_deepvariant} samtools index ${params.sample}.sorted.bam
    """
}

process CALL_DEEPVARIANT {

    cpus params.threads
    publishDir "results/deepvariant", mode: 'copy'

    input:
        tuple path(bam), path(bai), path(reference), path(fai)

    output:
        path "${params.sample}.deepvariant.vcf.gz"

    script:
    """
    singularity exec ${params.sif_deepvariant} \
      /opt/deepvariant/bin/run_deepvariant \
      --model_type=${params.model_type} \
      --ref=${reference} \
      --reads=${bam} \
      --output_vcf=${params.sample}.deepvariant.vcf.gz \
      --num_shards=${task.cpus}
    """
}

process CALL_CLAIR3 {

    cpus params.threads
    publishDir "results/clair3", mode: 'copy'

    input:
        tuple path(bam), path(reference)

    output:
        path "${params.sample}.clair3.vcf.gz"

    script:
    """
    singularity exec ${params.sif_clair3} \
      /opt/bin/run_clair3.sh \
      -b ${bam} \
      -f ${reference} \
      -m ${params.model_path} \
      -p hifi \
      -t ${task.cpus} \
      -o clair3_out

    cp clair3_out/merge_output.vcf.gz ${params.sample}.clair3.vcf.gz
    """
}

process HAPPY_CLAIR3 {

    cpus params.threads
    publishDir "bench/results", mode: 'copy'

    input:
        tuple path(truth_vcf), path(query_vcf), path(truth_bed), path(reference), path(fai)

    script:
    """
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    singularity exec ${params.sif_happy} \
      /opt/hap.py/bin/hap.py \
      ${truth_vcf} \
      ${query_vcf} \
      -f ${truth_bed} \
      -r ${reference} \
      -o clair3_happy \
      --engine=vcfeval \
      --threads=${task.cpus}
    """
}

process HAPPY_DEEPVARIANT {

    cpus params.threads
    publishDir "bench/results", mode: 'copy'

    input:
        tuple path(truth_vcf), path(query_vcf), path(truth_bed), path(reference), path(fai)

    script:
    """
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    singularity exec ${params.sif_happy} \
      /opt/hap.py/bin/hap.py \
      ${truth_vcf} \
      ${query_vcf} \
      -f ${truth_bed} \
      -r ${reference} \
      -o deepvariant_happy \
      --engine=vcfeval \
      --threads=${task.cpus}
    """
}
