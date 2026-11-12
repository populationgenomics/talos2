#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
The shared Talos pipeline: ANNOTATION -> SV_ANNOTATION -> TALOS, for any number of cohorts.

Entrypoints differ only in how they build the cohort rows and decide where each cohort's outputs go (see
docs/adr/0001). Everything from here down is layout-agnostic: each row carries its own output directories,
and nothing below this workflow builds an output path.
*/

include { ANNOTATION } from './annotation'
include { SV_ANNOTATION } from './sv_annotation'
include { TALOS } from './talos'


workflow TALOS_PIPELINE {
	take:
		// one Map per cohort: every input TSV column (cohort, path, type, pedigree, config, and the optional
		// history, ext_ids, seqr_map, mito, sv, sv_annotated, str), plus annotated_dir and analysis_dir - the
		// String URIs this cohort's annotation products and analysis results are published to - and optionally
		// report_dir, where the HTML report is published (default: analysis_dir)
		ch_cohorts_raw

	main:
	if (!file(params.mane_json).exists()) {
		println "MANE JSON not available, please run the Talos Prep workflow (--entry preparation)"
		exit 1
	}

	if (!params.ensembl_gff) {
		println "params.ensembl_gff (${params.ensembl_gff}) is not available, please re-run the input file download script & preparation.nf workflow"
		exit 1
	}

	ch_gff = channel.fromPath(params.ensembl_gff, checkIfExists: true).first()
	ch_ref_genome = channel.fromPath(params.ref_genome, checkIfExists: true).first()
	ch_mane = channel.fromPath(params.mane_json, checkIfExists: true).first()

	// `sv` is a raw joint-call to annotate, `sv_annotated` an already annotated one (e.g. GATK-SV output) that
	// skips SV_ANNOTATION. Both on one row is ambiguous - which one should be analysed?
	ch_cohorts = ch_cohorts_raw.map { row ->
		if (row.sv && row.sv_annotated) {
			error("Cohort ${row.cohort} sets both `sv` (${row.sv}) and `sv_annotated` (${row.sv_annotated}), supply one or the other")
		}
		row
	}

	ch_inputs = ch_cohorts.map { row -> tuple(
		row.cohort,
		row.path,
		row.type,
		file(row.pedigree, checkIfExists: true),
		row.annotated_dir,
	) }

	// per-cohort metadata, one row per cohort - the annotated shards are carried separately
	ch_talos_meta = ch_cohorts.map { row -> tuple(
		row.cohort,
		file(row.pedigree, checkIfExists: true),
		file(row.config, checkIfExists: true),
		// optional columns - an empty/absent cell becomes [], which stages nothing and is falsy in every downstream truthiness check
		row.history ? file(row.history, checkIfExists: true) : [],
		row.ext_ids ? file(row.ext_ids, checkIfExists: true) : [],
		row.seqr_map ? file(row.seqr_map, checkIfExists: true) : [],
		row.mito ? file(row.mito, checkIfExists: true) : [],
		// STR VCFs (from stripy_json_to_vcf) need no annotation, they go straight to ValidateMOI
		row.str ? file(row.str, checkIfExists: true) : [],
		row.analysis_dir,
	) }

	// where each cohort's HTML report is published, as [cohort, report_dir]
	ch_report_dirs = ch_cohorts.map { row -> tuple(row.cohort, row.report_dir ?: row.analysis_dir) }

	// SV annotation is wired up for every cohort, and decided per row: a cohort with no `sv` VCF carries [],
	// and drops out in SV_ANNOTATION's no_sv branch. The SV reference data is therefore always required
	ch_sv_inputs = ch_cohorts.map { row -> tuple(
		row.cohort,
		row.sv ? file(row.sv, checkIfExists: true) : [],
		file(row.config, checkIfExists: true),
		file(row.pedigree, checkIfExists: true),
		row.annotated_dir,
	) }

	SV_ANNOTATION(
		ch_ref_genome,
		ch_sv_inputs,
	)

	// pre-annotated SV VCFs bypass SV_ANNOTATION, joining its output in the same [cohort, vcf, tbi] shape.
	// Their AF fields aren't renamed, so the cohort config's RunSvFiltering.gnomad_population must match the
	// VCF's own field prefix
	ch_sv_preannotated = ch_cohorts
		.filter { row -> row.sv_annotated }
		.map { row -> tuple(
			row.cohort,
			file(row.sv_annotated, checkIfExists: true),
			file("${row.sv_annotated}.tbi", checkIfExists: true),
		) }

	ANNOTATION(
		ch_gff,
		ch_ref_genome,
		ch_inputs,
	)

	TALOS(
		ch_mane,
		ch_gff,
		ch_ref_genome,
		ch_talos_meta,
		ANNOTATION.out.shards,
		SV_ANNOTATION.out.annotated.mix(ch_sv_preannotated),
		ch_report_dirs,
	)

	emit:
		// one entry per cohort: [cohort, results_json], the task-local results JSON - its published copy is
		// <analysis_dir>/<name>
		json = TALOS.out.json
		// one entry per cohort: [cohort, report_html], published to <report_dir>/<name>
		html = TALOS.out.html
}
