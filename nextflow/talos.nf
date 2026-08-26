#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { AnnotateMitoVcf } from './modules/talos/AnnotateMitoVcf/main'
include { AnnotateVcfWithFreshClinvar } from './modules/talos/AnnotateVcfWithFreshClinvar/main'
include { ConcatLabelledVcfs } from './modules/talos/ConcatLabelledVcfs/main'
include { UnifiedPanelAppParser } from './modules/talos/UnifiedPanelAppParser/main'
include { RunSvFiltering } from './modules/talos/RunSvFiltering/main'
include { RunStreamingFiltering } from './modules/talos/RunStreamingFiltering/main'
include { ValidateMOI } from './modules/talos/ValidateMOI/main'
include { HPOFlagging } from './modules/talos/HPOFlagging/main'
include { CreateTalosHTML } from './modules/talos/CreateTalosHTML/main'
include { StartupChecks } from './modules/talos/StartupChecks/main'

workflow TALOS {
	take:
		ch_mane
		ch_gff
		ch_ref_genome
		// one entry per cohort: [cohort, pedigree, config, history, ext_ids, seqr_map, [mito, sv]]
		ch_meta
		// one entry per annotated shard: [cohort, vcf]
		ch_shards
		ch_sv_annotated

    main:
    // existence of these files is necessary for starting the workflow
    // we open them as a channel, and pass the channel through to the method
    ch_hpo_file = channel.fromPath(params.hpo, checkIfExists: true).first()
    ch_gen2phen = channel.fromPath(params.gen2phen, checkIfExists: true).first()
    ch_phenio = channel.fromPath(params.phenio_db, checkIfExists: true).first()

    // current year-month as a String, used to prompt for up to date resource updates
    def current_month = new java.util.Date().format('yyyy-MM')
    def timestamp = new java.util.Date().format('yyyy-MM-dd')

    // check if clinvar and panelapp data exist using the timestamp
    // the "all" VCF carries every decision (Benign included), and is the echtvar annotation source
    // for both the small-variant and mito paths - the zip below is the encoded form of it
    String current_clinvarbitration_pm5 = "${params.processed_annotations}/clinvarbitration_${current_month}.pm5.json"
    String current_clinvarbitration_zip = "${params.processed_annotations}/clinvarbitration_${current_month}.zip"

    if (!file(current_clinvarbitration_pm5).exists() || !file(current_clinvarbitration_zip).exists()) {
        println "ClinvArbitration data for this month (=${current_clinvarbitration_pm5}, ${current_clinvarbitration_zip}) doesn't exist, run the Talos Prep workflow"
        exit 1
    }

    // read in each Clinvar input source as channel
    ch_clinvar_pm5 = channel.fromPath(current_clinvarbitration_pm5, checkIfExists: true).first()
    // pre-encoded by the preparation workflow, once per month - fans out across every shard of every cohort
    ch_clinvar_zip = channel.fromPath(current_clinvarbitration_zip, checkIfExists: true).first()

    String panelapp_path = "${params.processed_annotations}/panelapp_${current_month}.json"

    if (!file(panelapp_path).exists()) {
        println "PanelApp data for this month (${panelapp_path}) doesn't exist, run the Talos Prep workflow"
        exit 1
    }
    ch_panelapp = channel.fromPath(panelapp_path, checkIfExists: true).first()

    // run pre-Talos startup checks, tasting the first shard to arrive for each cohort. Grouping the
    // cohort first would delay the checks until every shard was annotated, which is the opposite of
    // what they are for - the cost is that which shard gets checked can vary between runs, so this
    // (cheap) process is not reliably -resume cacheable
    ch_first_shards = ch_shards
        .unique { it[0] }
        .join(ch_meta)
        .map { cohort, vcf, pedigree, config, _history, _ext, _seqr, _mito ->
            tuple(cohort, vcf, pedigree, config)
        }

    StartupChecks(
        ch_first_shards,
    )

    // UnifiedPanelAppParser
    ch_panel_app_inputs = StartupChecks.out
        .join(ch_meta)
        .map { cohort, check_file, pedigree, config, _history, _ext, _seqr, _mito ->
            tuple(cohort, check_file, config, pedigree)
        }

    UnifiedPanelAppParser(
        ch_panel_app_inputs,
    	ch_panelapp,
    	ch_hpo_file,
    )

    // apply this run's ClinVar to every shard, then filter and label each one independently
    AnnotateVcfWithFreshClinvar(
        ch_shards,
        ch_clinvar_zip,
    )

    // combine (not join) - the per-cohort metadata is repeated across every shard of that cohort
    ch_streaming_inputs = AnnotateVcfWithFreshClinvar.out
        .combine(UnifiedPanelAppParser.out, by: 0)
        .combine(ch_meta, by: 0)
        .map { cohort, vcf, panelapp_data, pedigree, config, _history, _ext, _seqr, _mito ->
            tuple(cohort, vcf, panelapp_data, pedigree, config)
        }

    RunStreamingFiltering(
        ch_streaming_inputs,
        ch_mane,
        ch_clinvar_pm5,
    )

    // gather the labelled shards back to one VCF per cohort
    ConcatLabelledVcfs(
        RunStreamingFiltering.out.groupTuple(by: 0),
    )

    // filter & label any annotated SV VCFs. ch_sv_annotated only carries cohorts that had SV data, so this
    // inner join naturally restricts the process to those cohorts
    ch_run_hail_sv_inputs = ch_sv_annotated
        .join(UnifiedPanelAppParser.out)
        .join(ch_meta)
        .map { cohort, sv_vcf, sv_idx, panelapp_data, pedigree, config, _history, _ext, _seqr, _mito ->
            tuple(cohort, sv_vcf, sv_idx, panelapp_data, pedigree, config)
        }

    RunSvFiltering(
        ch_run_hail_sv_inputs,
        ch_mane,
    )

    // re-attach an empty placeholder for every cohort without SV data, so ValidateMOI runs for all cohorts.
    // Deliberately not `join(..., remainder: true)`: the shape of a remainder emission depends on
    // Nextflow inferring the right-hand channel's arity, which it cannot do when that channel never
    // emits (no cohort had SV data). It then emits the bare cohort key instead of [cohort, null], and
    // indexing that String yields its first character, silently emptying every downstream join.
    // Offering [] for every cohort and letting a real SV VCF displace it has one fixed shape
    ch_sv_placeholder = ch_meta.map { row -> tuple(row[0], []) }

    ch_sv_resolved = RunSvFiltering.out
        .map { cohort, sv_vcf, _sv_idx -> tuple(cohort, sv_vcf) }
        .mix(ch_sv_placeholder)
        .groupTuple(by: 0)
        .map { cohort, sv_vcfs -> tuple(cohort, sv_vcfs.find { it } ?: []) }

    // surprise! It's Mito data!
    ch_mito_joined = ch_meta
        .join(UnifiedPanelAppParser.out)
        .join(StartupChecks.out)
        .map { cohort, pedigree, config, _history, _ext, _seqr, mito, panelapp_data, _check_file ->
          tuple(cohort, mito, panelapp_data, pedigree, config)
    }

    // absent mito data is [] (falsy), a real VCF is a truthy Path
    ch_mito_branched = ch_mito_joined.branch {
        real:  it[1]
        empty: true
    }

    ch_mito_for_annotation = ch_mito_branched.real
        .map { cohort, mito, panelapp, ped, config ->
            tuple(cohort, mito, panelapp, ped, config,
                  file(params.mitimpact_zip, checkIfExists: true),
                  file(params.mitotip_zip, checkIfExists: true),
                  file(params.napogee_zip, checkIfExists: true))
        }

    AnnotateMitoVcf(
        ch_mito_for_annotation,
        ch_ref_genome,
        ch_gff,
        ch_clinvar_zip,
    )

    ch_mito_resolved = AnnotateMitoVcf.out
        .mix(ch_mito_branched.empty.map { cohort, mito, _pa, _ped, _cfg -> tuple(cohort, mito) })

    // Validate MOI of all variants
    ch_validate_moi_inputs = ConcatLabelledVcfs.out
        .join(UnifiedPanelAppParser.out)
        .join(ch_meta)
        .join(ch_mito_resolved)
        .join(ch_sv_resolved)
        .map { cohort, labelled_vcf, labelled_vcf_index, panelapp_out, pedigree, config, history, _ext, _seqr, _mito, anno_mito, anno_sv ->
            tuple(cohort, labelled_vcf, labelled_vcf_index, anno_sv, anno_mito, panelapp_out, pedigree, config, history)
        }

    ValidateMOI(
        ch_validate_moi_inputs,
        timestamp,
    )

    // Flag any relevant HPO terms
    ch_hpo_inputs = ValidateMOI.out
        .join(UnifiedPanelAppParser.out)
        .join(ch_meta)
        .map { cohort, talos_result_json, panelapp_data, _pedigree, config, _history, _ext, _seqr, _mito ->
            tuple(cohort, talos_result_json, panelapp_data, config)
        }

    HPOFlagging(
        ch_hpo_inputs,
        ch_gen2phen,
        ch_phenio,
        timestamp,
    )

    // Generate HTML report
    ch_create_html_inputs = HPOFlagging.out
        .join(UnifiedPanelAppParser.out)
        .join(ch_meta)
        .map { cohort, result_json, panelapp_data, _pedigree, config, _history, ext, seqr, _mito ->
            tuple(cohort, result_json, panelapp_data, config, ext, seqr)
        }

    CreateTalosHTML(
        ch_create_html_inputs,
        timestamp,
    )

    emit:
    	json = HPOFlagging.out
    	html = CreateTalosHTML.out
    	labelled = ConcatLabelledVcfs.out
    	labelled_sv = RunSvFiltering.out
    	panelapp = UnifiedPanelAppParser.out
}
