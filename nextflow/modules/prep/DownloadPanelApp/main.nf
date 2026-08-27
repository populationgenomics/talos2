process DownloadPanelApp {
    container params.container

    input:
        val timestamp

    output:
        path "panelapp_${timestamp}.json"

    script:
        """
        set -euo pipefail

        python -m talos2.download_panelapp --output panelapp_${timestamp}.json
        """
}
