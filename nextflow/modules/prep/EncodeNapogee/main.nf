process EncodeNapogee {
    container params.container

    input:
        path tsv

    output:
        tuple path("napogee.vcf.gz"), path("napogee.zip")

    script:
        """
        set -euo pipefail

        python -m talos2.scripts.parse_napogee \
            --input ${tsv} \
            --output napogee.vcf.gz

        echtvar encode napogee.zip /talos2/echtvar/napogee_config.json napogee.vcf.gz
        """
}
