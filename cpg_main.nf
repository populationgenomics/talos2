#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
    Talos Workflow - CPG entrypoint
    ===============================

    Runs the shared TALOS_PIPELINE (nextflow/talos_pipeline.nf) over a set of Metamist cohorts, each publishing
    to its own dataset bucket:

        gs://cpg-<dataset>-{main|test}/<sequencing_type>/talos/<cohort>/annotated/
        gs://cpg-<dataset>-{main|test}/<sequencing_type>/talos/<cohort>/analysis_YYYYMMDD/

    The first process, InputTsvFromMetamist, finds each cohort's inputs in Metamist and generates the rest
    (pedigree, external IDs, seqr map, per-cohort config) into that cohort's analysis_YYYYMMDD/inputs/. Its TSV
    then feeds TALOS_PIPELINE exactly as main.nf's input TSV would. There is no next-cycle TSV: history is the
    dataset's latest aip-results analysis in Metamist. This run's results aren't registered there yet - see
    docs/CpgDeployment.md.

    Outputs are published with publishDir, not workflow outputs - see docs/adr/0001.

    Usage:
    nextflow run cpg_main.nf --cohort_ids COH0001,COH0002 --access_level test --sequencing_type genome \
        --talos_config gs://.../talos.toml [other params...]
*/

include { InputTsvFromMetamist } from './nextflow/modules/cpg/InputTsvFromMetamist/main'
include { TALOS_PIPELINE } from './nextflow/talos_pipeline'

// fixed once per run - InputTsvFromMetamist writes each cohort's generated inputs under analysis_<runDate>, so the
// published results must land in the same directory
def runDate() {
    workflow.start.format(java.time.format.DateTimeFormatter.ofPattern('yyyyMMdd'))
}

// a list (e.g. from a params file) or a comma-delimited string, as a list of unique IDs
def cohortIds() {
    def raw = params.cohort_ids instanceof List ? params.cohort_ids : params.cohort_ids.toString().split(',')
    raw.collect { cohort_id -> cohort_id.toString().trim() }.findAll { cohort_id -> cohort_id }.unique()
}

// must agree with cohort_root() in talos.cpg_internal.input_tsv_from_metamist. Plain Strings, never a Path
def cohortRoot(dataset, cohort) {
    def bucket = "gs://cpg-${dataset}-${params.access_level == 'test' ? 'test' : 'main'}"
    "${bucket}/${params.sequencing_type}/talos/${cohort}".toString()
}

def annotatedDir(dataset, cohort) {
    "${cohortRoot(dataset, cohort)}/annotated".toString()
}

def analysisDir(dataset, cohort) {
    "${cohortRoot(dataset, cohort)}/analysis_${runDate()}".toString()
}


workflow {
	main:
	if (!params.cohort_ids || !cohortIds()) {
		println "Required --cohort_ids argument not provided"
		exit 1
	}

	if (!(params.access_level in ['test', 'standard', 'full'])) {
		println "--access_level must be one of test, standard, full (got ${params.access_level})"
		exit 1
	}

	if (!(params.sequencing_type in ['genome', 'exome'])) {
		println "--sequencing_type must be one of genome, exome (got ${params.sequencing_type})"
		exit 1
	}

	if (!params.talos_config) {
		println "Required --talos_config argument not provided"
		exit 1
	}

	InputTsvFromMetamist(
		cohortIds(),
		params.access_level,
		params.sequencing_type,
		file(params.talos_config, checkIfExists: true),
		runDate(),
	)

	// one Map per cohort: the generated TSV row, plus where that cohort's outputs are published
	ch_cohorts = InputTsvFromMetamist.out
		.splitCsv(header: true, sep: '\t')
		.map { row -> row + [
			annotated_dir: annotatedDir(row.cpg_dataset, row.cohort),
			analysis_dir: analysisDir(row.cpg_dataset, row.cohort),
		] }

	TALOS_PIPELINE(ch_cohorts)
}
