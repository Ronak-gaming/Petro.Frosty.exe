#!/usr/bin/env bash
set -uo pipefail

create_panel_admin() {
    echo ""
    echo "== Creating Pterodactyl Administrator =="

    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }

    # Check if an admin already exists
    local admin_count
    admin_count="$(php"${FROSTY_PHP_VERSION:-8.3}" artisan tinker --execute="echo \Pterodactyl\Models\User::where('root_admin', true)->count();" 2>/dev/null | tail -1)"

    if [[ "$admin_count" =~ ^[0-9]+$ ]] && [[ "$admin_count" -gt 0 ]]; then
        _frosty_ok "Administrator account already exists ($admin_count found) — skipping creation"
        return 0
    fi

    echo -e "    ${C_CYAN:-}Enter details for the Panel administrator account:${C_RESET:-}"
    echo ""

    if php"${FROSTY_PHP_VERSION:-8.3}" artisan p:user:make; then
        _frosty_ok "Administrator account created"
    else
        _frosty_fail "Administrator creation failed or was cancelled"
        return 1
    fi

    return 0
}
