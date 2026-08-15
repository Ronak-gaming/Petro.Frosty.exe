#!/usr/bin/env bash
set -uo pipefail

FROSTY_WINGS_CONFIG="/etc/pterodactyl/config.yml"

_frosty_wings_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

install_wings() {
    echo ""
    echo "== Installing Wings =="

    if command -v wings >/dev/null 2>&1 && wings version >/dev/null 2>&1; then
        _frosty_ok "Wings already installed: $(wings version 2>/dev/null | head -1)"
    else
        mkdir -p /etc/pterodactyl

        local cf_arch
        cf_arch="$(_frosty_wings_arch)"
        if [[ -z "$cf_arch" ]]; then
            _frosty_fail "Unsupported architecture for Wings: $(uname -m)"
            return 1
        fi

        echo "    Downloading Wings binary (${cf_arch})..."
        if curl -L -o /usr/local/bin/wings \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${cf_arch}" \
            >/tmp/frosty_wings_download.log 2>&1; then
            chmod u+x /usr/local/bin/wings
        else
            _frosty_fail "Wings download failed — see /tmp/frosty_wings_download.log"
            return 1
        fi

        if wings version >/dev/null 2>&1; then
            _frosty_ok "Wings installed: $(wings version 2>/dev/null | head -1)"
        else
            _frosty_fail "Wings binary downloaded but does not execute correctly"
            return 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        _frosty_fail "Docker is not installed/running — Wings requires Docker. Install Panel first (Docker is included) or run Docker setup."
        return 1
    fi
    _frosty_ok "Docker verified available for Wings"

    return 0
}

configure_wings() {
    echo ""
    echo -e "${C_CYAN:-}== Configure Wings ==${C_RESET:-}"
    echo ""
    echo "  Steps to get your deploy command:"
    echo "    1. Log into your Panel as admin"
    echo "    2. Go to Admin -> Locations -> create a location (if you don't have one)"
    echo "    3. Go to Admin -> Nodes -> Create New, fill in details, save"
    echo "    4. Open the new node -> Configuration tab"
    echo "    5. Copy the full 'wings configure' command shown there"
    echo "       (starts with something like: sudo wings configure --panel-url ...)"
    echo ""
    read -rp "  Paste the full deploy command here: " deploy_cmd

    if [[ -z "$deploy_cmd" ]]; then
        _frosty_fail "No command entered"
        return 1
    fi

    if [[ "$deploy_cmd" != *"wings configure"* ]]; then
        _frosty_fail "That doesn't look like a 'wings configure' command — please copy it exactly from the node's Configuration tab"
        return 1
    fi

    deploy_cmd="${deploy_cmd#sudo }"

    echo "    Running configuration..."
    if eval "$deploy_cmd" >/tmp/frosty_wings_configure.log 2>&1; then
        _frosty_ok "Wings configured"
    else
        _frosty_fail "Wings configuration command failed — see /tmp/frosty_wings_configure.log"
        tail -15 /tmp/frosty_wings_configure.log
        return 1
    fi

    if [[ ! -f "$FROSTY_WINGS_CONFIG" ]]; then
        _frosty_fail "Expected config not found at ${FROSTY_WINGS_CONFIG} after configure"
        return 1
    fi

    _frosty_ok "Config verified at ${FROSTY_WINGS_CONFIG}"
    return 0
}

setup_wings_service() {
    echo ""
    echo "== Setting Up Wings Service =="

    if [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/wings.service << SVCEOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
        systemctl enable wings >/dev/null 2>&1
        systemctl restart wings >/dev/null 2>&1
        sleep 3

        if systemctl is-active --quiet wings; then
            _frosty_ok "Wings service running"
        else
            _frosty_fail "Wings service failed to start"
            systemctl status wings --no-pager | tail -20
            return 1
        fi
    else
        _frosty_warn "No systemd — starting Wings manually in background"
        pkill -f "^/usr/local/bin/wings" >/dev/null 2>&1
        cd /etc/pterodactyl || return 1
        nohup wings >/tmp/frosty_wings_run.log 2>&1 &
        sleep 3
        if pgrep -f "^/usr/local/bin/wings" >/dev/null 2>&1; then
            _frosty_ok "Wings running (background process)"
        else
            _frosty_fail "Wings failed to start — see /tmp/frosty_wings_run.log"
            tail -15 /tmp/frosty_wings_run.log
            return 1
        fi
    fi

    local node_ok
    node_ok="$(curl -s -o /dev/null -w '%{http_code}' -k https://localhost:8080/api/system 2>/dev/null)"
    if [[ "$node_ok" == "200" || "$node_ok" == "401" || "$node_ok" == "403" ]]; then
        _frosty_ok "Wings API responding on :8080"
    else
        _frosty_warn "Wings API check on :8080 returned: ${node_ok:-no response} (may still be starting up)"
    fi

    return 0
}

wings_installed() {
    command -v wings >/dev/null 2>&1 && [[ -f "$FROSTY_WINGS_CONFIG" ]]
}

wings_reconfigure() {
    configure_wings && setup_wings_service
}

wings_update() {
    echo ""
    echo "== Updating Wings =="

    if [[ -d /run/systemd/system ]]; then
        systemctl stop wings >/dev/null 2>&1
    else
        pkill -f "^/usr/local/bin/wings" >/dev/null 2>&1
    fi

    local cf_arch
    cf_arch="$(_frosty_wings_arch)"
    if [[ -z "$cf_arch" ]]; then
        _frosty_fail "Unsupported architecture: $(uname -m)"
        return 1
    fi

    echo "    Downloading latest Wings binary..."
    if curl -L -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${cf_arch}" \
        >/tmp/frosty_wings_update.log 2>&1; then
        chmod u+x /usr/local/bin/wings
        if wings version >/dev/null 2>&1; then
            _frosty_ok "Wings updated: $(wings version 2>/dev/null | head -1)"
        else
            _frosty_fail "New Wings binary does not execute correctly"
            return 1
        fi
    else
        _frosty_fail "Wings update download failed — see /tmp/frosty_wings_update.log"
        return 1
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl start wings >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet wings; then
            _frosty_ok "Wings restarted successfully"
        else
            _frosty_fail "Wings failed to restart after update"
            return 1
        fi
    else
        cd /etc/pterodactyl || return 1
        nohup wings >/tmp/frosty_wings_run.log 2>&1 &
        sleep 2
        _frosty_ok "Wings restarted (background process)"
    fi

    return 0
}

wings_uninstall() {
    echo ""
    echo -e "${C_RED}== Uninstall Wings ==${C_RESET}"
    read -rp "  Type UNINSTALL to confirm: " confirm

    if [[ "$confirm" != "UNINSTALL" ]]; then
        echo "Cancelled."
        return 1
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl stop wings >/dev/null 2>&1
        systemctl disable wings >/dev/null 2>&1
        rm -f /etc/systemd/system/wings.service
        systemctl daemon-reload
    else
        pkill -f "^/usr/local/bin/wings" >/dev/null 2>&1
    fi

    rm -rf /etc/pterodactyl
    rm -f /usr/local/bin/wings

    _frosty_ok "Wings uninstalled"
    echo -e "    ${C_YELLOW:-}Remember to also delete the node in the Panel admin UI.${C_RESET:-}"
    return 0
}

show_wings_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}        ${C_ICE}${C_BOLD}❄  W I N G S   M A N A G E R  ❄${C_RESET}        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Reconfigure (new node token)${C_RESET}             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Update Wings${C_RESET}                             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[3]${C_RESET} ${C_WHITE}Uninstall Wings${C_RESET}                          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[4]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-4]: " sub_choice

    case "$sub_choice" in
        1) wings_reconfigure ;;
        2) wings_update ;;
        3) wings_uninstall ;;
        4) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
}
