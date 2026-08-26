#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
    Talos Unified Workflow
    ======================

    This is the single entry point for the Talos pipeline. It orchestrates three workflows:

    1. ANNOTATION: Annotates VCF file(s) with the prepared data.
    2. SV_ANNOTATION: Annotates a joint-called SV VCF, if the input TSV carries an `sv` column.
    3. TALOS: Runs the core Talos analysis/filtering/reporting.

    Annotation (small-variant and SV alike) is idempotent: cohorts whose annotation products are
    already published (keyed on the shard manifest / annotated SV VCF) are reused, not re-annotated.
    A reanalysis cycle is simply re-running this workflow; delete a cohort's `${cohort}_annotated`
    directory to force re-annotation.

    Usage:
    nextflow run main.nf --input_tsv [path] [other params...]
*/

// Import specific workflows
include { ANNOTATION } from './nextflow/annotation'
include { SV_ANNOTATION } from './nextflow/sv_annotation'
include { TALOS } from './nextflow/talos'

// analysis outputs are published to a per-run dated directory, ${cohort}_analysis_YYYYMMDD -
// annotation products go to the undated ${cohort}_annotated, which is reused across cycles
def runDate() {
    workflow.start.format(java.time.format.DateTimeFormatter.ofPattern('yyyyMMdd'))
}


workflow {
	main:
	if (file(workflow.outputDir).simpleName == file(params.processed_annotations).simpleName) {
    	println "Output Directory (${workflow.outputDir}) is probably not set correctly, use config or `-output-dir`"
		exit 1
    }

	if (!file(params.mane_json).exists()) {
		println "MANE JSON not available, please run the Talos Prep workflow (--entry preparation)"
		exit 1
	}

	if (!params.input_tsv) {
		println "Required --input_tsv argument not provided"
		exit 1
	}

	if (!params.ensembl_gff) {
		println "params.ensembl_gff (${params.ensembl_gff}) is not available, please re-run the input file download script & preparation.nf workflow"
		exit 1
	}

	ch_gff = channel.fromPath(params.ensembl_gff, checkIfExists: true).first()
	ch_ref_genome = channel.fromPath(params.ref_genome, checkIfExists: true).first()
	ch_mane = channel.fromPath(params.mane_json, checkIfExists: true).first()

	ch_inputs = channel.fromPath(params.input_tsv)
		.splitCsv(header: true, sep: '\t')
		.map { row -> tuple(row.cohort, row.path, row.type) }

	// per-cohort metadata, one row per cohort - the annotated shards are carried separately
	ch_talos_meta = channel.fromPath(params.input_tsv)
		.splitCsv(header: true, sep: '\t')
		.map { row -> tuple(
			row.cohort,
			file(row.pedigree, checkIfExists: true),
			file(row.config, checkIfExists: true),
			// optional columns - an empty/absent cell becomes [], which stages nothing and is falsy in every downstream truthiness check
			row.history ? file(row.history, checkIfExists: true) : [],
			row.ext_ids ? file(row.ext_ids, checkIfExists: true) : [],
			row.seqr_map ? file(row.seqr_map, checkIfExists: true) : [],
			row.mito ? file(row.mito, checkIfExists: true) : [],
		) }

	// the SV path is entirely optional, and only wired up if the input TSV declares an `sv` column.
	// this is checked eagerly rather than per-row so that a cohort with no SV data never requires SV reference files
	def sv_requested = file(params.input_tsv).withReader { handle -> handle.readLine() }.tokenize('\t').contains('sv')

	ch_sv_annotated = channel.empty()
	ch_sv_fresh = channel.empty()

	if (sv_requested) {
		ch_sv_inputs = channel.fromPath(params.input_tsv)
			.splitCsv(header: true, sep: '\t')
			.map { row -> tuple(
				row.cohort,
				row.sv ? file(row.sv, checkIfExists: true) : [],
				file(row.config, checkIfExists: true),
			) }

		SV_ANNOTATION(
			ch_ref_genome,
			ch_sv_inputs,
		)

		ch_sv_annotated = SV_ANNOTATION.out.annotated
		ch_sv_fresh = SV_ANNOTATION.out.fresh
	}

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
		ch_sv_annotated,
	)

	publish:
		// newly annotated products only - reused shards/SV VCFs are already published on disk
		annotated = ANNOTATION.out.new_shards
		annotated_manifest = ANNOTATION.out.manifest
		sv_annotated = ch_sv_fresh
    	html = TALOS.out.html
		json = TALOS.out.json
		labelled = TALOS.out.labelled
		labelled_sv = TALOS.out.labelled_sv
		panelapp = TALOS.out.panelapp
}

output {
	// annotation products - undated, reused by every subsequent reanalysis cycle, and safe to
	// delete wholesale to force re-annotation without touching any analysis results
	annotated {
		path { id, _vcf -> "${id}_annotated" }
	}
	annotated_manifest {
		path { id, _manifest -> "${id}_annotated" }
	}
	sv_annotated {
		path { id, _vcf, _vcf_idx -> "${id}_annotated" }
	}
	// analysis results - one directory per analysis date
	html {
		path { id, _html -> "${id}_analysis_${runDate()}" }
	}
	json {
		path { id, _json -> "${id}_analysis_${runDate()}" }
	}
	panelapp {
		path { id, _panelapp -> "${id}_analysis_${runDate()}" }
	}
	labelled {
		path { id, _labelled, _labelled_idx -> "${id}_analysis_${runDate()}" }
	}
	labelled_sv {
		path { id, _labelled_sv, _labelled_sv_idx -> "${id}_analysis_${runDate()}" }
	}
}
