# SV Annotation Module

A Nextflow workflow which annotates a joint-called Structural Variant VCF with:

- **gene consequences**, using [GATK `SVAnnotate`](https://gatk.broadinstitute.org/hc/en-us/articles/13832752531611-SVAnnotate) against the MANE GTF
- **population allele frequencies**, using [SVAFotate](https://github.com/fakedrtom/SVAFotate) against gnomAD-SV

This is a re-implementation of the same core steps we (CPG) use internally. Our internal usage centres around the
GATK-SV workflow, and our CPG-Flow wrapped implementation of it. The terminal stage of this workflow is [Annotation](https://github.com/populationgenomics/cpg-flow-gatk-sv/blob/main/src/cpg_flow_gatk_sv/multisample_workflow.py#L701),
which is done using GATK's SvAnnotate tool for consequence prediction, and a complex interval-overlap-resolution step
to match variants to gnomAD frequencies.

Instead of re-implementing the exact process here, I've split the annotation into two phases:

  - Consequence: handled using SVAnnotate, and exact replica of the GATK-SV process
  - Pop.Freq: handled using [SVAFotate](https://github.com/fakedrtom/SVAFotate)

These two steps, and pre-processing of relevant input files, are engaged only if an SV file is included in the input
TSV file, with the same core conceit as small variants and Mito data - a single joint-called VCF should contain the whole
group of Samples being processed, which should also match the Pedigree and Small-variant data.

A separate sub-workflow, `SV_ANNOTATION` has been created to handle these steps. `SV_ANNOTATION` publishes an annotated
VCF per cohort, `RunSmallFilteringSv` filters and labels it with `CategoryBooleanSV1`, and `ValidateMOI` folds the result
into the report.

To utilise this functionality, add a `sv` column to the input TSV, pointing to a SV joint-call. This has been tested on
the output of GATK-SV (multiple variant callers, with resolved calls) and GATK's gCNV.
