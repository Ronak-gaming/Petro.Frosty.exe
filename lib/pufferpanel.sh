#!/usr/bin/env bash
set -uo pipefail

# PufferPanel (official apt repository, signed key). Panel: 8080, SFTP: 5657.
FROSTY_PUFFER_PORT="${FROSTY_PUFFER_PORT:-8080}"
FROSTY_PUFFER_SFTP_PORT=5657
FROSTY_PUFFER_WRAPPER="/usr/local/sbin/frosty-pufferpanel.sh"

declare -F _frosty_menu_row >/dev/null 2>&1 || _frosty_menu_row() {
    local color="$1" label="$2" text="$3" pad
    pad=$(( 45 - ${#label} - ${#text} )); (( pad < 1 )) && pad=1
    printf '%b\n' "${C_FROST}${C_BOLD}║${C_RESET}  ${color}${label}${C_RESET} ${C_WHITE}${text}${C_RESET}$(printf '%*s' "$pad" '')${C_FROST}${C_BOLD}║${C_RESET}"
}

pufferpanel_installed() {
    command -v pufferpanel >/dev/null 2>&1 || [[ -x /usr/sbin/pufferpanel ]]
}

_frosty_puffer_has_systemd() { [[ -d /run/systemd/system ]]; }

_frosty_puffer_exec_line() {
    grep -h -m1 '^ExecStart=' /lib/systemd/system/pufferpanel.service /usr/lib/systemd/system/pufferpanel.service 2>/dev/null \
        | head -1 | cut -d= -f2-
}

_frosty_puffer_start_pm2() {
    local line
    line="$(_frosty_puffer_exec_line)"
    [[ -z "$line" ]] && line="/usr/sbin/pufferpanel run"
    mkdir -p /var/lib/pufferpanel
    printf '#!/bin/bash\nexec %s\n' "$line" > "$FROSTY_PUFFER_WRAPPER"
    chmod 755 "$FROSTY_PUFFER_WRAPPER"
    load_module "pm2.sh"
    _frosty_ensure_pm2_always >/dev/null 2>&1
    _frosty_pm2_start "pufferpanel" "/var/lib/pufferpanel" "bash" "$FROSTY_PUFFER_WRAPPER"
}

_frosty_puffer_wait_http() {
    local i code
    for i in $(seq 1 20); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:${FROSTY_PUFFER_PORT}/" 2>/dev/null)"
        [[ "$code" =~ ^(200|30[0-9]|40[0-9])$ ]] && return 0
        sleep 1
    done
    return 1
}

install_pufferpanel() {
    echo ""
    echo -e "${C_CYAN:-}== Installing PufferPanel ==${C_RESET:-}"

    if [[ "${EUID}" -ne 0 ]]; then _frosty_fail "Run as root"; return 1; fi
    if ! command -v apt-get >/dev/null 2>&1; then
        _frosty_fail "Only Debian/Ubuntu (apt) is supported by this installer"
        return 1
    fi
    if pufferpanel_installed; then
        _frosty_ok "PufferPanel already installed: $(pufferpanel version 2>/dev/null | head -1)"
        return 0
    fi

    echo "    Installing prerequisites..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates >/tmp/frosty_puffer_deps.log 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates >>/tmp/frosty_puffer_deps.log 2>&1; then
            _frosty_fail "Prerequisite install failed — see /tmp/frosty_puffer_deps.log"
            return 1
        fi
    fi

    echo "    Adding the official PufferPanel repository..."
    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL --retry 3 -m 60 https://packagecloud.io/pufferpanel/pufferpanel/gpgkey 2>/tmp/frosty_puffer_key.log \
        | gpg --dearmor --yes -o /etc/apt/keyrings/pufferpanel.gpg 2>>/tmp/frosty_puffer_key.log; then
        _frosty_fail "Could not fetch the repository signing key — see /tmp/frosty_puffer_key.log"
        return 1
    fi
    chmod 644 /etc/apt/keyrings/pufferpanel.gpg
    cat > /etc/apt/sources.list.d/pufferpanel.sources << 'SRC'
X-Repolib-Name: PufferPanel
Types: deb
URIs: https://packagecloud.io/pufferpanel/pufferpanel/any/
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/pufferpanel.gpg
SRC

    echo "    Installing the package (this can take a minute)..."
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y pufferpanel; } >/tmp/frosty_puffer_install.log 2>&1; then
        _frosty_fail "PufferPanel install failed — see /tmp/frosty_puffer_install.log"
        tail -n 6 /tmp/frosty_puffer_install.log | sed 's/^/      /'
        return 1
    fi
    _frosty_ok "PufferPanel package installed"

    if command -v docker >/dev/null 2>&1 && id pufferpanel >/dev/null 2>&1; then
        getent group docker >/dev/null 2>&1 || groupadd --system docker >/dev/null 2>&1
        usermod -aG docker pufferpanel >/dev/null 2>&1 && _frosty_ok "pufferpanel user added to the docker group (Docker servers enabled)"
    fi

    if _frosty_puffer_has_systemd; then
        systemctl daemon-reload >/dev/null 2>&1
        if systemctl enable --now pufferpanel >/dev/null 2>&1; then
            _frosty_ok "pufferpanel service enabled and started"
        else
            _frosty_fail "Could not start the pufferpanel service — check: journalctl -u pufferpanel -n 50"
        fi
    else
        _frosty_warn "No systemd — running PufferPanel under pm2 for persistence"
        _frosty_puffer_start_pm2
    fi

    if _frosty_puffer_wait_http; then
        _frosty_ok "Web panel is answering on port ${FROSTY_PUFFER_PORT}"
    else
        _frosty_warn "Panel not answering yet — check logs (option in the PufferPanel menu)"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${FROSTY_PUFFER_PORT}/tcp" >/dev/null 2>&1
        ufw allow "${FROSTY_PUFFER_SFTP_PORT}/tcp" >/dev/null 2>&1
        _frosty_ok "ufw: opened ${FROSTY_PUFFER_PORT}/tcp and ${FROSTY_PUFFER_SFTP_PORT}/tcp"
    fi

    echo ""
    read -rp "  Create the first admin user now? [Y/n]: " mk_admin
    if [[ "${mk_admin:-Y}" =~ ^[Yy] ]]; then
        pufferpanel_add_user
    else
        echo "    Later: sudo pufferpanel user add   (answer Y to 'Admin')"
    fi

    local ip
    ip="$(curl -s -4 -m 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    echo -e "${C_CYAN:-}    ─────────────────────────────────────${C_RESET:-}"
    echo -e "${C_WHITE:-}    Panel:${C_RESET:-} http://${ip:-<server-ip>}:${FROSTY_PUFFER_PORT}"
    echo -e "${C_WHITE:-}    SFTP :${C_RESET:-} port ${FROSTY_PUFFER_SFTP_PORT}"
    echo -e "${C_WHITE:-}    Cloudflare Tunnel service:${C_RESET:-} http://localhost:${FROSTY_PUFFER_PORT}"
    echo -e "${C_CYAN:-}    ─────────────────────────────────────${C_RESET:-}"
    return 0
}

pufferpanel_add_user() {
    if ! pufferpanel_installed; then _frosty_fail "PufferPanel is not installed"; return 1; fi
    echo ""
    echo -e "${C_CYAN:-}== Add PufferPanel User ==${C_RESET:-}"
    echo "    Answer Y when asked 'Admin' to get full access."
    pufferpanel user add
}

pufferpanel_restart() {
    if _frosty_puffer_has_systemd; then
        systemctl restart pufferpanel && _frosty_ok "pufferpanel restarted" || _frosty_fail "Restart failed — journalctl -u pufferpanel -n 50"
    else
        load_module "pm2.sh"
        local pm2_bin; pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        if [[ -n "$pm2_bin" ]] && "$pm2_bin" restart pufferpanel >/dev/null 2>&1; then
            _frosty_ok "pufferpanel restarted (pm2)"
        else
            _frosty_puffer_start_pm2
        fi
    fi
}

pufferpanel_logs() {
    if _frosty_puffer_has_systemd; then
        journalctl -u pufferpanel -n 60 --no-pager
    else
        load_module "pm2.sh"
        local pm2_bin; pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" logs pufferpanel --lines 60 --nostream
    fi
}

pufferpanel_status() {
    echo ""
    if _frosty_puffer_has_systemd; then
        systemctl is-active pufferpanel 2>/dev/null | sed 's/^/    service: /'
    else
        load_module "pm2.sh"
        local pm2_bin; pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" describe pufferpanel 2>/dev/null | grep -E 'status|uptime|restarts' | sed 's/^/    /'
    fi
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://127.0.0.1:${FROSTY_PUFFER_PORT}/" 2>/dev/null)"
    echo "    http://127.0.0.1:${FROSTY_PUFFER_PORT} -> HTTP ${code:-no response}"
}

update_pufferpanel() {
    echo ""
    echo -e "${C_CYAN:-}== Updating PufferPanel ==${C_RESET:-}"
    if ! pufferpanel_installed; then _frosty_fail "PufferPanel is not installed"; return 1; fi
    if DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_puffer_update.log 2>&1 \
       && DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade pufferpanel >>/tmp/frosty_puffer_update.log 2>&1; then
        _frosty_ok "Updated: $(pufferpanel version 2>/dev/null | head -1)"
        pufferpanel_restart
    else
        _frosty_fail "Update failed — see /tmp/frosty_puffer_update.log"
        return 1
    fi
}

uninstall_pufferpanel() {
    echo ""
    echo -e "${C_RED:-}== Uninstall PufferPanel ==${C_RESET:-}"
    if ! pufferpanel_installed; then _frosty_fail "PufferPanel is not installed"; return 1; fi
    read -rp "  Type YES to remove the PufferPanel package: " c1
    [[ "$c1" == "YES" ]] || { echo "Cancelled."; return 1; }

    if _frosty_puffer_has_systemd; then
        systemctl disable --now pufferpanel >/dev/null 2>&1
    else
        load_module "pm2.sh"
        local pm2_bin; pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && { "$pm2_bin" delete pufferpanel >/dev/null 2>&1; "$pm2_bin" save >/dev/null 2>&1; }
        rm -f "$FROSTY_PUFFER_WRAPPER"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get remove -y pufferpanel >/tmp/frosty_puffer_remove.log 2>&1 \
        && _frosty_ok "Package removed" || _frosty_fail "Remove failed — see /tmp/frosty_puffer_remove.log"

    read -rp "  Also DELETE all PufferPanel data (servers, users, config)? Type DELETE to confirm, Enter to keep: " c2
    if [[ "$c2" == "DELETE" ]]; then
        rm -rf /var/lib/pufferpanel /etc/pufferpanel
        _frosty_ok "Data deleted"
    else
        _frosty_ok "Data kept in /var/lib/pufferpanel and /etc/pufferpanel"
    fi
    rm -f /etc/apt/sources.list.d/pufferpanel.sources /etc/apt/keyrings/pufferpanel.gpg
}

show_pufferpanel_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}$(_frosty_center "${C_ICE}${C_BOLD}P U F F E R P A N E L${C_RESET}" 48)${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠════════════════════════════════════════════════╣${C_RESET}"
    if pufferpanel_installed; then
        _frosty_menu_row "$C_GREEN" "Status:" "installed"
    else
        _frosty_menu_row "$C_RED" "Status:" "not installed"
    fi
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    _frosty_menu_row "$C_CYAN"   "[1]" "Install PufferPanel"
    _frosty_menu_row "$C_GREEN"  "[2]" "Add / Create User (admin)"
    _frosty_menu_row "$C_PURPLE" "[3]" "Restart"
    _frosty_menu_row "$C_ICE"    "[4]" "Status"
    _frosty_menu_row "$C_ICE"    "[5]" "View Logs"
    _frosty_menu_row "$C_YELLOW" "[6]" "Update"
    _frosty_menu_row "$C_RED"    "[7]" "Uninstall"
    _frosty_menu_row "$C_BLUE"   "[8]" "Back"
    echo -e "${C_FROST}${C_BOLD}╚════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-8]: " puf_choice

    case "$puf_choice" in
        1) install_pufferpanel ;;
        2) pufferpanel_add_user ;;
        3) pufferpanel_restart ;;
        4) pufferpanel_status ;;
        5) pufferpanel_logs ;;
        6) update_pufferpanel ;;
        7) uninstall_pufferpanel ;;
        8) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_pufferpanel_submenu
}

run_pufferpanel_flow() {
    show_pufferpanel_submenu
}
