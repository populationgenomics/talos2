process EncodeMitimpact {
    container params.container

    input:
        path tsv

    output:
        tuple path("mitimpact.vcf.gz"), path("mitimpact.zip")

    script:
        """
        set -euo pipefail

        python -m talos2.scripts.parse_mitimpact \
            --input ${tsv} \
            --output mitimpact.vcf.gz

        echtvar encode mitimpact.zip /talos2/echtvar/mitimpact_config.json mitimpact.vcf.gz
        """
}
