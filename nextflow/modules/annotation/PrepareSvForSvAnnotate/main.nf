process PrepareSvForSvAnnotate {
    container params.container

    input:
        tuple val(cohort), path(vcf), path(tbi)

    // same VCF, minus any record with a non-symbolic ALT, with each complex variant's CPX_INTERVALS sorted
    output:
        tuple val(cohort), path("${cohort}_svannotate_ready.vcf.bgz"), path("${cohort}_svannotate_ready.vcf.bgz.tbi")

    script:
        // GATK SVAnnotate assumes CPX_INTERVALS is coordinate-sorted and aborts the whole run on the first
        // record where it is not - GATK-SV writes delINVdel as DEL,DEL,INV, which trips it immediately.
        // SVAnnotate also only works with symbolic alleles, so records with a non-symbolic ALT are removed here,
        // and each removed record is logged. Full reasoning lives in the script's docstring.
        // This runs ahead of AnnotateSvWithGatk rather than inside it because it needs the Talos container,
        // not the GATK one.
        """
        set -euo pipefail

        python -m talos.scripts.prepare_sv_for_svannotate \
            --input ${vcf} \
            --output ${cohort}_svannotate_ready.vcf

        bgzip -c ${cohort}_svannotate_ready.vcf > ${cohort}_svannotate_ready.vcf.bgz
        tabix -p vcf ${cohort}_svannotate_ready.vcf.bgz
        """
}
