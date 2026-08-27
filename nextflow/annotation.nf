#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
This workflow is the annotation process for the Talos pipeline.

It requires a single VCF, which can be single- or multi-sample. This is then annotated and reformatted for Talos.
The specific annotations are:

- gnomAD v4.1 frequencies and alphamissense annotations, applied to the joint VCF using echtvar
- Transcript consequences, using BCFtools annotate

Everything here is cohort-agnostic and cacheable. Output is the annotated VCF shards themselves -
MANE and ClinVar are applied in the per-run workflow, where the labelling happens.
*/

include { AnnotateCsqWithBcftools } from './modules/annotation/AnnotateCsqWithBcftools/main'
include { AnnotateWithEchtvar } from './modules/annotation/AnnotateWithEchtvar/main'
include { IndexVcf } from './modules/annotation/IndexVcf/main'
include { MakeScatterRegions } from './modules/annotation/MakeScatterRegions/main'
include { MergeVcfsWithBcftools } from './modules/annotation/MergeVcfsWithBcftools/main'
include { NormaliseVcf } from './modules/annotation/NormaliseVcf/main'
include { WriteShardManifest } from './modules/annotation/WriteShardManifest/main'


// read a cohort's shard manifest and return [cohort, shard] tuples for every listed shard.
// The manifest - never a directory glob - decides which shards are consumed, so shards left
// behind by an earlier annotation run (e.g. with a different vcf_split_n) are never double-counted
def shardsFromManifest(cohort, dir, manifest, source) {
    def parsed = new groovy.json.JsonSlurper().parseText(manifest.text)
    def listed = parsed.shards as Set
    def stale = dir.listFiles().findAll { it.name.endsWith('_csq.vcf.bgz') && !listed.contains(it.name) }
    if (stale) {
        println "WARNING: ${cohort}: ignoring ${stale.size()} shard(s) in ${dir} not listed in the manifest: ${stale*.name.join(', ')}"
    }
    if (parsed.vcf_split_n != params.vcf_split_n) {
        println "WARNING: ${cohort}: existing shards were generated with vcf_split_n=${parsed.vcf_split_n} (current setting ${params.vcf_split_n}) - delete ${dir} to re-annotate"
    }
    if (parsed.source != source.toString()) {
        println "WARNING: ${cohort}: existing shards were generated from ${parsed.source}, not the current input (${source}) - delete ${dir} to re-annotate"
    }
    return parsed.shards.collect { name ->
        def shard = dir.resolve(name)
        if (!shard.exists()) {
            error("Manifest for ${cohort} lists ${name}, but it is missing from ${dir}")
        }
        tuple(cohort, shard)
    }
}


workflow ANNOTATION {
	take:
		ch_gff
		ch_ref_genome
		ch_inputs

    main:
    // populate various input channels - these are downloaded by the large_files/gather_files.sh script, or the prep wf
    if (!file(params.alphamissense_zip).exists()) {
        println "AlphaMissense data must be encoded for echtvar, run the Talos Prep workflow (talos_preparation.nf)"
        exit 1
    }
    ch_alphamissense_zip = channel.fromPath(params.alphamissense_zip, checkIfExists: true).first()

    ch_gnomad_zip = channel.fromPath(params.gnomad_zip, checkIfExists: true).first()

    // skip annotation entirely for cohorts whose shard manifest already exists - reuse the
    // published shards instead. Annotation is expensive and its inputs stable; delete the
    // cohort's `${cohort}_annotated` directory to force re-annotation
    def annotated_root = params.annotated_dir ?: workflow.outputDir
    ch_reuse_branched = ch_inputs.branch { row ->
        complete: file("${annotated_root}/${row[0]}_annotated/${row[0]}_manifest.json").exists()
        pending:  true
    }

    ch_complete_shards = ch_reuse_branched.complete.flatMap { row ->
        def cohort = row[0]
        def dir = file("${annotated_root}/${cohort}_annotated")
        def manifest = dir.resolve("${cohort}_manifest.json")
        println "Annotated shards for ${cohort} already exist (${manifest}), skipping annotation"
        shardsFromManifest(cohort, dir, manifest, row[1])
    }

    ch_inputs_branched = ch_reuse_branched.pending.branch {
        shards: it[2] == 'shards'
        vcf_dir: it[2] == 'ss_vcf_dir'
        single_vcf: it[2] == 'vcf'
    }

    // Process shards
    ch_from_shards = ch_inputs_branched.shards.flatMap { cohort, path, _type ->
        def vcfs = files("${path}/*.${params.input_vcf_extension}")
        vcfs.collect { vcf -> tuple(cohort, vcf) }
    }

    // Process single-sample components
    ch_vcf_dir_inputs = ch_inputs_branched.vcf_dir.map { cohort, path, _type ->
        def vcfs = files("${path}/*.${params.input_vcf_extension}")
        def tbis = vcfs.collect { file("${it}.tbi") }
        tuple(cohort, vcfs, tbis)
    }

    MergeVcfsWithBcftools(
        ch_vcf_dir_inputs,
        ch_ref_genome,
    )
    ch_merged_vcfs = MergeVcfsWithBcftools.out

    // Process single VCF - reuse an index sitting next to the input, build one otherwise
    ch_single_vcfs = ch_inputs_branched.single_vcf.map { cohort, path, _type ->
        tuple(cohort, file(path, checkIfExists: true))
    }
    // sibling resolution stays on the Path object. Interpolating a cloud path into a string
    // drops the gs:// scheme, which sent every indexed input down the re-index branch as the index wasn't local
    ch_singles_branched = ch_single_vcfs.branch {
        indexed: it[1].resolveSibling("${it[1].name}.tbi").exists()
        unindexed: true
    }

    // An index is essential for the MergedVCF to be split into approximately even fragments
    // This can be avoided by providing a multisample VCF with a corresponding TBI file
    IndexVcf(ch_singles_branched.unindexed)
    ch_singles_indexed = ch_singles_branched.indexed
        .map { cohort, vcf -> tuple(cohort, vcf, vcf.resolveSibling("${vcf.name}.tbi")) }
        .mix(ch_singles_branched.unindexed.join(IndexVcf.out))

    // Combine single VCFs and merged VCFs, as [cohort, vcf, tbi]
    ch_whole_vcfs = ch_singles_indexed.mix(ch_merged_vcfs)

    // the scatter is virtual: derive density-weighted regions from the index alone (the VCF is
    // never staged for this), then fan the whole VCF out across them - each NormaliseVcf task
    // reads only its region's blocks through the tbi
    if ((params.vcf_split_n ?: 0) > 0) {
        MakeScatterRegions(ch_whole_vcfs.map { cohort, _vcf, tbi -> tuple(cohort, tbi) })
        ch_regions = MakeScatterRegions.out
            .splitText(elem: 1)
            .map { cohort, region -> tuple(cohort, region.trim()) }
        // combine (not join) - every region row repeats that cohort's vcf+tbi
        ch_vcfs = ch_whole_vcfs.combine(ch_regions, by: 0)
    } else {
        ch_vcfs = ch_whole_vcfs.map { cohort, vcf, tbi -> tuple(cohort, vcf, tbi, 'all') }
    }

    // mix in pre-sharded inputs - streamed whole ('all'), so no index is needed ([] stages nothing)
    ch_all_vcfs = ch_vcfs.mix(
        ch_from_shards.map { cohort, vcf -> tuple(cohort, vcf, [], 'all') }
    )

	NormaliseVcf(
        ch_all_vcfs,
        ch_ref_genome,
    )

	AnnotateWithEchtvar(
        NormaliseVcf.out,
        ch_gnomad_zip,
        ch_alphamissense_zip,
    )

    // annotate transcript consequences with bcftools csq
    AnnotateCsqWithBcftools(
        AnnotateWithEchtvar.out,
        ch_gff,
        ch_ref_genome,
    )

    // gather each cohort's shard names into a manifest, alongside the input identity and split
    // setting - the manifest existence check above reads this on the next run, and it names
    // exactly the shards to consume, so no directory globbing is ever needed
    ch_shard_names = AnnotateCsqWithBcftools.out
        .map { cohort, vcf -> tuple(cohort, vcf.name) }
        .groupTuple(by: 0)
    WriteShardManifest(ch_shard_names.join(ch_reuse_branched.pending))

    emit:
        // one entry per shard, as [cohort, vcf], newly annotated and reused alike - the per-run workflow keeps the scatter open
    	shards = AnnotateCsqWithBcftools.out.mix(ch_complete_shards)
        // newly annotated shards only - these need publishing, reused ones are already on disk
        new_shards = AnnotateCsqWithBcftools.out
        // one entry per newly annotated cohort, as [cohort, manifest_json]
        manifest = WriteShardManifest.out
}
