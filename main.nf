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

    Outputs are published with publishDir, not workflow outputs - see docs/adr/0001. This entrypoint
    decides each cohort's output directories and passes them down in the cohort tuples; nothing below
    it knows the output layout.

    Usage:
    nextflow run main.nf --input_tsv [path] --outdir [path] [other params...]
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

// output directories are carried as plain Strings built from params.outdir (itself a String), never
// by interpolating a Path - that drops the gs:// scheme from cloud paths
def outRoot() {
    params.outdir.toString().replaceAll('/+$', '')
}

def annotatedDir(cohort) {
    "${outRoot()}/${cohort}_annotated".toString()
}

def analysisDir(cohort) {
    "${outRoot()}/${cohort}_analysis_${runDate()}".toString()
}

// build the content of a proposed input TSV for the next reanalysis cycle: this run's input TSV
// verbatim, except each cohort's `history` cell now points at the results JSON this run produced.
// resultsByCohort maps cohort -> published results JSON path; cohorts absent from it keep whatever
// history they were given
def nextInputTsv(input_tsv, resultsByCohort) {
    def lines = input_tsv.readLines().findAll { line -> line.trim() }
    // split with a negative limit - trailing empty cells matter here, they are the optional columns
    def header = lines[0].split('\t', -1) as List
    if (!header.contains('history')) {
        header << 'history'
    }
    def cohort_idx = header.indexOf('cohort')
    def history_idx = header.indexOf('history')

    def rows = [header.join('\t')]
    lines.drop(1).each { line ->
        def raw = line.split('\t', -1) as List
        // rows commonly omit trailing empty cells altogether, so pad out to the header width
        def cells = raw.size() < header.size() ? raw + [''] * (header.size() - raw.size()) : raw
        def cohort = cells[cohort_idx]
        if (resultsByCohort.containsKey(cohort)) {
            cells[history_idx] = resultsByCohort[cohort]
        }
        rows << cells.join('\t')
    }
    return rows.join('\n') + '\n'
}


workflow {
	main:
	if (!params.outdir) {
		println "Required --outdir argument not provided"
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
		.map { row -> tuple(row.cohort, row.path, row.type, annotatedDir(row.cohort)) }

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
			// STR VCFs (from stripy_json_to_vcf) need no annotation, they go straight to ValidateMOI
			row.str ? file(row.str, checkIfExists: true) : [],
			analysisDir(row.cohort),
		) }

	// the SV path is entirely optional, and only wired up if the input TSV declares an `sv` column.
	// this is checked eagerly rather than per-row so that a cohort with no SV data never requires SV reference files
	def sv_requested = file(params.input_tsv).withReader { handle -> handle.readLine() }.tokenize('\t').contains('sv')

	ch_sv_annotated = channel.empty()

	if (sv_requested) {
		ch_sv_inputs = channel.fromPath(params.input_tsv)
			.splitCsv(header: true, sep: '\t')
			.map { row -> tuple(
				row.cohort,
				row.sv ? file(row.sv, checkIfExists: true) : [],
				file(row.config, checkIfExists: true),
				annotatedDir(row.cohort),
			) }

		SV_ANNOTATION(
			ch_ref_genome,
			ch_sv_inputs,
		)

		ch_sv_annotated = SV_ANNOTATION.out.annotated
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

	// a ready-to-use input TSV for the next reanalysis cycle - identical to this run's input, with
	// `history` repointed at the results JSON published for that cohort by this run, written to the
	// root of the output directory. The paths are the published destinations, which don't exist until
	// the run completes, so this is a proposal to be reviewed, not an output consumed by anything in this run
	TALOS.out.json
		.map { cohort, results_json -> tuple(cohort, "${analysisDir(cohort)}/${results_json.name}".toString()) }
		.collect(flat: false)
		.map { pairs -> nextInputTsv(file(params.input_tsv), pairs.collectEntries { pair -> pair }) }
		.collectFile(name: "talos_input_${runDate()}.tsv", storeDir: file(outRoot()))
}
