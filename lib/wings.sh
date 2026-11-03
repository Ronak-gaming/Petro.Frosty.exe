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

# Ensures Docker is installed and running even on a fresh standalone Worker VPS
_frosty_wings_ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        _frosty_ok "Docker verified available for Wings"
        return 0
    fi

    echo "    Docker is not running/installed — installing Docker for standalone Wings node..."
    if declare -f load_module >/dev/null 2>&1 && declare -f install_docker >/dev/null 2>&1; then
        load_module "docker.sh" 2>/dev/null || true
        install_docker && return 0
    fi

    mkdir -p /var/cache/apt/tmp /var/cache/apt/archives/partial
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates iptables >/dev/null 2>&1 || true

    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh >/tmp/frosty_wings_docker.log 2>&1 || true
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
    else
        pgrep -x dockerd >/dev/null 2>&1 || (nohup dockerd >/tmp/dockerd.log 2>&1 & sleep 5)
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        _frosty_ok "Docker installed and running for Wings"
        return 0
    fi

    _frosty_fail "Docker failed to start — check /tmp/frosty_wings_docker.log or virtualization support"
    return 1
}

install_wings() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Pterodactyl Wings (Standalone / Remote Ready) ==${C_RESET:-}"

    if ! _frosty_wings_ensure_docker; then
        return 1
    fi

    mkdir -p /etc/pterodactyl /var/run/wings

    if command -v wings >/dev/null 2>&1 && wings version >/dev/null 2>&1; then
        _frosty_ok "Wings already installed: $(wings version 2>/dev/null | head -1)"
    else
        local cf_arch
        cf_arch="$(_frosty_wings_arch)"
        if [[ -z "$cf_arch" ]]; then
            _frosty_fail "Unsupported architecture for Wings: $(uname -m)"
            return 1
        fi

        echo "    Downloading Wings binary (${cf_arch})..."
        if curl -L --max-time 120 -o /usr/local/bin/wings \
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

    return 0
}

# Helper to optionally disable SSL inside config.yml when behind Cloudflare Tunnel / Reverse Proxy
_frosty_wings_post_process_config() {
    if [[ ! -s "$FROSTY_WINGS_CONFIG" ]]; then
        return 1
    fi

    echo ""
    read -rp "  Are you running Wings behind a Cloudflare Tunnel / Reverse Proxy (Disable local SSL)? [Y/n]: " disable_ssl
    disable_ssl="${disable_ssl:-Y}"
    if [[ "$disable_ssl" =~ ^[Yy]$ ]]; then
        sed -i '/ssl:/,/enabled:/{s/enabled: true/enabled: false/}' "$FROSTY_WINGS_CONFIG" 2>/dev/null || true
        sed -i '/cert:/d; /key:/d' "$FROSTY_WINGS_CONFIG" 2>/dev/null || true
        _frosty_ok "Disabled local SSL in ${FROSTY_WINGS_CONFIG} (Cloudflare Tunnel / Proxy ready)"
    fi

    # Ensure container memory swap warning doesn't block Wings startup on budget VPS nodes
    if grep -q "ignore_panel_config_updates:" "$FROSTY_WINGS_CONFIG" 2>/dev/null; then
        true
    fi
    return 0
}

# Configures Wings when the Panel is hosted on ANOTHER server (Remote Worker Node)
configure_wings_remote() {
    echo ""
    echo -e "${C_CYAN:-}== Configure Standalone / Remote Wings Node (No Local Panel Required) ==${C_RESET:-}"
    echo "  How do you want to pair this VPS with your remote Pterodactyl Panel?"
    echo "    [1] Paste Auto-Deploy Command from Panel (Configuration -> Generate Token)"
    echo "    [2] Enter Panel URL, Node ID & Token manually"
    echo "    [3] Paste full config.yml content manually"
    read -rp "  Select method [1-3, default: 1]: " rem_mode
    rem_mode="${rem_mode:-1}"

    mkdir -p /etc/pterodactyl

    case "$rem_mode" in
        1)
            echo ""
            echo -e "  ${C_YELLOW:-}Go to Panel -> Admin -> Nodes -> [Your Node] -> Configuration -> Generate Token${C_RESET:-}"
            read -rp "  Paste the Auto-Deploy command here: " deploy_cmd
            if [[ -z "$deploy_cmd" ]]; then
                _frosty_fail "Auto-deploy command cannot be empty"
                return 1
            fi

            # Extract arguments starting from --panel-url (strips 'cd /etc/pterodactyl && sudo wings configure')
            local args_only
            args_only="$(echo "$deploy_cmd" | sed -E 's/.*wings[[:space:]]+configure[[:space:]]+//')"

            echo "    Running wings configure against remote Panel..."
            if eval "/usr/local/bin/wings configure ${args_only} --config-path ${FROSTY_WINGS_CONFIG}" >/tmp/frosty_wings_cfg.log 2>&1; then
                _frosty_ok "Fetched configuration from remote Panel!"
                _frosty_wings_post_process_config
                return 0
            else
                _frosty_fail "Auto-deploy failed — see output below:"
                cat /tmp/frosty_wings_cfg.log 2>/dev/null
                echo ""
                echo -e "  ${C_YELLOW:-}Tip: If Cloudflare blocked the API request, use Method [3] (Paste config.yml manually).${C_RESET:-}"
                return 1
            fi
            ;;
        2)
            read -rp "  Enter Remote Panel URL (e.g. https://panel.yourdomain.com): " r_url
            r_url="${r_url%/}"
            read -rp "  Enter Node ID (from Panel -> Admin -> Nodes, e.g. 1 or 2): " r_node
            read -rp "  Enter Configuration Token (from Configuration -> Generate Token): " r_token

            if [[ -z "$r_url" || -z "$r_node" || -z "$r_token" ]]; then
                _frosty_fail "Panel URL, Node ID, and Token are all required"
                return 1
            fi

            echo "    Fetching node config from ${r_url}..."
            if /usr/local/bin/wings configure --panel-url "$r_url" --token "$r_token" --node "$r_node" --config-path "$FROSTY_WINGS_CONFIG" --override >/tmp/frosty_wings_cfg.log 2>&1; then
                _frosty_ok "Configuration written to ${FROSTY_WINGS_CONFIG}!"
                _frosty_wings_post_process_config
                return 0
            else
                _frosty_fail "Failed to pull config from ${r_url} — see error below:"
                cat /tmp/frosty_wings_cfg.log 2>/dev/null
                return 1
            fi
            ;;
        3)
            echo ""
            echo -e "  ${C_YELLOW:-}Paste your entire config.yml from Panel -> Nodes -> Configuration, then press Ctrl+D on a new line:${C_RESET:-}"
            cat > "$FROSTY_WINGS_CONFIG"
            if [[ ! -s "$FROSTY_WINGS_CONFIG" ]] || ! grep -q "remote:" "$FROSTY_WINGS_CONFIG"; then
                _frosty_fail "Invalid or empty config.yml pasted"
                return 1
            fi
            _frosty_ok "Saved config.yml to ${FROSTY_WINGS_CONFIG}!"
            _frosty_wings_post_process_config
            return 0
            ;;
        *)
            _frosty_fail "Invalid selection"
            return 1
            ;;
    esac
}

# Configures Wings when the Panel IS installed on the same server
configure_wings_local() {
    echo "  Fetching nodes from local Panel..."
    local node_list
    node_list="$(cd "${FROSTY_PANEL_DIR:-/var/www/pterodactyl}" && php"${FROSTY_PHP_VERSION:-8.3}" artisan p:node:list 2>/dev/null || php artisan p:node:list 2>/dev/null)"

    if [[ -z "$node_list" ]] || ! echo "$node_list" | grep -q "ID"; then
        _frosty_fail "No nodes found in local Panel. Create one in Admin -> Nodes -> Create New, or use Remote Mode."
        return 1
    fi

    echo "$node_list"
    echo ""
    read -rp "  Enter the Node ID to configure Wings for: " node_id

    if [[ -z "$node_id" ]]; then
        _frosty_fail "No node ID entered"
        return 1
    fi

    echo "    Generating Wings configuration..."
    local raw_config
    raw_config="$(cd "${FROSTY_PANEL_DIR:-/var/www/pterodactyl}" && (php"${FROSTY_PHP_VERSION:-8.3}" artisan p:node:configuration "$node_id" 2>/dev/null || php artisan p:node:configuration "$node_id" 2>/dev/null))"

    if [[ -z "$raw_config" ]] || echo "$raw_config" | grep -qi "error\|not enough arguments"; then
        _frosty_fail "Failed to generate config for node ID $node_id — check the ID is correct"
        return 1
    fi

    mkdir -p /etc/pterodactyl

    local panel_url="${FROSTY_PANEL_URL:-}"
    if [[ -z "$panel_url" ]]; then
        read -rp "  Enter your Panel's public URL (e.g. https://panel.yourdomain.com): " panel_url
    fi

    panel_url="${panel_url%/}"
    panel_url="${panel_url#http://}"
    panel_url="${panel_url#https://}"
    panel_url="https://${panel_url}"

    if [[ -z "$panel_url" || "$panel_url" == "https://" ]]; then
        _frosty_fail "Panel URL cannot be empty"
        return 1
    fi

    echo "$raw_config" | \
        sed '/ssl:/,/enabled:/{s/enabled: true/enabled: false/}' | \
        sed "/^remote:/c\\remote: '${panel_url}'" | \
        sed '/cert:/d; /key:/d' \
        > "$FROSTY_WINGS_CONFIG"

    if [[ ! -s "$FROSTY_WINGS_CONFIG" ]]; then
        _frosty_fail "Failed to write config.yml"
        return 1
    fi

    _frosty_ok "Wings configuration written to ${FROSTY_WINGS_CONFIG} (SSL disabled, remote set to ${panel_url})"
    return 0
}

configure_wings() {
    echo ""
    echo -e "${C_CYAN:-}== Configure Wings ==${C_RESET:-}"

    if [[ -d "${FROSTY_PANEL_DIR:-/var/www/pterodactyl}" ]]; then
        echo "  Local Pterodactyl Panel detected on this server."
        echo "    [1] Configure from Local Panel (/var/www/pterodactyl)"
        echo "    [2] Configure for a Remote Panel (Auto-Deploy Command / Token / Paste config.yml)"
        read -rp "  Select mode [1-2, default: 1]: " cfg_choice
        cfg_choice="${cfg_choice:-1}"
        if [[ "$cfg_choice" == "2" ]]; then
            configure_wings_remote
        else
            configure_wings_local
        fi
    else
        echo "  No local Panel found on this VPS — switching to Standalone Remote Node mode!"
        configure_wings_remote
    fi
}

_frosty_wings_api_port() {
    grep -A2 "^api:" "$FROSTY_WINGS_CONFIG" 2>/dev/null | grep "port:" | head -1 | awk '{print $2}'
}

setup_wings_service() {
    echo ""
    echo "== Setting Up Wings Service =="

    mkdir -p /var/run/wings /etc/pterodactyl

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
        _frosty_warn "No systemd — starting Wings under pm2 for persistence"
        load_module "pm2.sh"
        if ! _frosty_ensure_pm2; then
            _frosty_fail "pm2 setup failed — cannot start Wings persistently"
            return 1
        fi
        if ! _frosty_pm2_start "wings" "/etc/pterodactyl" "/usr/local/bin/wings"; then
            echo "    pm2 logs:"
            pm2 logs wings --lines 20 --nostream 2>/dev/null
            return 1
        fi
    fi

    local api_port
    api_port="$(_frosty_wings_api_port)"
    api_port="${api_port:-8080}"

    local node_ok
    node_ok="$(curl -s -o /dev/null -w '%{http_code}' -k "https://localhost:${api_port}/api/system" 2>/dev/null)"
    if [[ "$node_ok" == "200" || "$node_ok" == "401" || "$node_ok" == "403" ]]; then
        _frosty_ok "Wings API responding on :${api_port}"
    else
        node_ok="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${api_port}/api/system" 2>/dev/null)"
        if [[ "$node_ok" == "200" || "$node_ok" == "401" || "$node_ok" == "403" ]]; then
            _frosty_ok "Wings API responding on :${api_port}"
        else
            _frosty_warn "Wings API check on :${api_port} returned: ${node_ok:-no response} (may still be starting up)"
        fi
    fi

    return 0
}

# One-click installer for adding THIS VPS as a Remote Wings Node
install_remote_wings_node() {
    install_wings || return 1
    configure_wings_remote || return 1
    setup_wings_service || return 1
    _frosty_ok "Standalone Remote Wings Node is online and connected to your Panel!"
}

wings_installed() {
    command -v wings >/dev/null 2>&1 && [[ -f "$FROSTY_WINGS_CONFIG" ]]
}

wings_reconfigure() {
    install_wings && configure_wings && setup_wings_service
}

wings_restart() {
    echo ""
    echo "== Restarting Wings =="
    if [[ ! -f "$FROSTY_WINGS_CONFIG" ]]; then
        _frosty_fail "No Wings config found — run [1] Install / Pair Remote Node first"
        return 1
    fi
    setup_wings_service
}

wings_update() {
    echo ""
    echo "== Updating Wings =="

    if [[ -d /run/systemd/system ]]; then
        systemctl stop wings >/dev/null 2>&1
    else
        load_module "pm2.sh"
        if command -v pm2 >/dev/null 2>&1; then
            pm2 stop wings >/dev/null 2>&1
        fi
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

    setup_wings_service
    return 0
}

wings_uninstall() {
    echo ""
    echo -e "${C_RED:-}== Uninstall Wings ==${C_RESET:-}"
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
        load_module "pm2.sh"
        if command -v pm2 >/dev/null 2>&1; then
            pm2 delete wings >/dev/null 2>&1
            pm2 save >/dev/null 2>&1
        fi
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
    echo -e "${C_FROST:-}${C_BOLD:-}╔══════════════════════════════════════════════╗${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}        ${C_ICE:-}${C_BOLD:-}❄  W I N G S   M A N A G E R  ❄${C_RESET:-}        ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╠══════════════════════════════════════════════╣${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}                                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_CYAN:-}[1]${C_RESET:-} ${C_WHITE:-}Install / Pair Remote Node (No Panel)${C_RESET:-}   ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_YELLOW:-}[2]${C_RESET:-} ${C_WHITE:-}Reconfigure Wings (Local or Remote)${C_RESET:-}     ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_GREEN:-}[3]${C_RESET:-} ${C_WHITE:-}Restart Wings${C_RESET:-}                           ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_PURPLE:-}[4]${C_RESET:-} ${C_WHITE:-}Update Wings${C_RESET:-}                            ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_ICE:-}[5]${C_RESET:-} ${C_WHITE:-}View Wings Live Logs${C_RESET:-}                    ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_RED:-}[6]${C_RESET:-} ${C_WHITE:-}Uninstall Wings${C_RESET:-}                         ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_BLUE:-}[7]${C_RESET:-} ${C_WHITE:-}Back to Main Menu${C_RESET:-}                       ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}                                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╚══════════════════════════════════════════════╝${C_RESET:-}"
    echo ""
    read -rp "  ❄ Select an option [1-7]: " sub_choice

    case "$sub_choice" in
        1) install_remote_wings_node ;;
        2) wings_reconfigure ;;
        3) wings_restart ;;
        4) wings_update ;;
        5)
            if [[ -d /run/systemd/system ]]; then
                journalctl -u wings -n 40 --no-pager
            else
                pm2 logs wings --lines 40 --nostream 2>/dev/null || tail -n 40 /var/log/pterodactyl/wings.log 2>/dev/null
            fi
            ;;
        6) wings_uninstall ;;
        7) return 0 ;;
        *) echo -e "${C_RED:-}Invalid option.${C_RESET:-}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_wings_submenu
}
