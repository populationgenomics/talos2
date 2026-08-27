process ParseManeIntoJson {
    container params.container

    input:
    	path mane_summary

    output:
        path "mane.json"

    script:
        """
        set -euo pipefail

        python -m talos2.scripts.parse_mane_into_json \
            --input ${mane_summary} \
            --output mane.json
        """
}
