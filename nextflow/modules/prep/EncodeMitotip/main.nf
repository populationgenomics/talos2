process EncodeMitotip {
    container params.container

    input:
        path tsv

    output:
        tuple path("mitotip.vcf.gz"), path("mitotip.zip")

    script:
        """
        set -euo pipefail

        python -m talos2.scripts.parse_mitotip \
            --input ${tsv} \
            --output mitotip.vcf.gz

        echtvar encode mitotip.zip /talos2/echtvar/mitotip_config.json mitotip.vcf.gz
        """
}
