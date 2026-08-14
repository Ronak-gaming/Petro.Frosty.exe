#!/usr/bin/env bash
set -uo pipefail

FROSTY_PANEL_DIR="/var/www/pterodactyl"

download_panel() {
    echo ""
    echo "== Downloading Pterodactyl Panel =="

    if [[ -f "${FROSTY_PANEL_DIR}/artisan" ]]; then
        _frosty_ok "Existing Panel installation detected at ${FROSTY_PANEL_DIR}"
        _frosty_warn "Skipping fresh download to avoid overwriting existing install"
        export FROSTY_PANEL_EXISTING=1
        return 0
    fi

    mkdir -p "${FROSTY_PANEL_DIR}"
    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Could not cd into ${FROSTY_PANEL_DIR}"; return 1; }

    echo "    Downloading panel.tar.gz from latest release..."
    if curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz >/tmp/frosty_panel_download.log 2>&1; then
        _frosty_ok "panel.tar.gz downloaded"
    else
        _frosty_fail "Panel download failed — see /tmp/frosty_panel_download.log"
        return 1
    fi

    echo "    Extracting archive..."
    if tar -xzf panel.tar.gz >/tmp/frosty_panel_extract.log 2>&1; then
        _frosty_ok "Panel extracted to ${FROSTY_PANEL_DIR}"
    else
        _frosty_fail "Extraction failed — see /tmp/frosty_panel_extract.log"
        return 1
    fi

    rm -f panel.tar.gz

    chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null

    if [[ -f "${FROSTY_PANEL_DIR}/artisan" ]]; then
        _frosty_ok "Panel files verified (artisan present)"
    else
        _frosty_fail "Panel files incomplete — artisan not found after extraction"
        return 1
    fi

    export FROSTY_PANEL_EXISTING=0
    return 0
}
