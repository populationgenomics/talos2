process RunSvFiltering {
    container params.container

    input:
        tuple val(cohort), path(sv_vcf), path(sv_index), path(panelapp_data), path(pedigree), path(talos_config)
        path mane_json

    output:
        tuple val(cohort), path("${cohort}_labelled_svs.vcf.bgz"), path("${cohort}_labelled_svs.vcf.bgz.tbi")

    script:
        """
        set -euo pipefail

        export TALOS_CONFIG=${talos_config}

        python -m talos2.run_sv_filtering \
            --input ${sv_vcf} \
            --panelapp ${panelapp_data} \
            --pedigree ${pedigree} \
            --output ${cohort}_labelled_svs.vcf.bgz

        tabix -p vcf ${cohort}_labelled_svs.vcf.bgz
        """
}
