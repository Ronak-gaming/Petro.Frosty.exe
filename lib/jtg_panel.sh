#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# JTG Panel — a Node.js/TypeScript game server panel by Jishnu
# (github.com/JishnuTheGamer/Jtg). Manages Docker containers
# directly via the Docker socket (no separate daemon like Wings).
# Confirmed real config from the repo's .env.example: PORT=6767,
# needs a JWT_SECRET, and DOCKER_SOCKET_PATH for container control.
# ============================================================

FROSTY_JTG_DIR="/opt/jtg-panel"

# Resolves a working pm2 command by absolute path where possible —
# `command -v pm2` right after installing it can be unreliable across
# shell contexts in this environment (same PATH inconsistency we hit
# with Blueprint earlier), so check common install locations directly
# instead of trusting bare `pm2` calls.
_frosty_jtg_pm2_cmd() {
    for candidate in \
        "$(npm root -g 2>/dev/null)/pm2/bin/pm2" \
        "/usr/local/lib/node_modules/pm2/bin/pm2" \
        "/usr/lib/node_modules/pm2/bin/pm2"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    if command -v pm2 >/dev/null 2>&1; then
        command -v pm2
        return 0
    fi
    echo ""
    return 1
}

jtg_panel_installed() {
    [[ -f "${FROSTY_JTG_DIR}/package.json" ]]
}

install_jtg_panel() {
    echo ""
    echo -e "${C_CYAN:-}== Installing JTG Panel ==${C_RESET:-}"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        _frosty_fail "Docker isn't installed/running — JTG Panel controls containers via the Docker socket and needs it"
        _frosty_warn "Install Docker first (Panels -> Petro -> Panel will set it up, or run it manually)"
        return 1
    fi
    _frosty_ok "Docker available"

    echo "    Installing Node.js 22 (if not already present)..."
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d v)" -lt 18 ]]; then
        mkdir -p /etc/apt/keyrings
        timeout 60 curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>/dev/null | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_jtg_node.log 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs git >>/tmp/frosty_jtg_node.log 2>&1
    fi
    if ! command -v node >/dev/null 2>&1; then
        _frosty_fail "Node.js install failed — see /tmp/frosty_jtg_node.log"
        return 1
    fi
    _frosty_ok "Node.js: $(node -v)"

    load_module "pm2.sh"
    _frosty_ensure_pm2 >/dev/null 2>&1

    # Verify pm2 is ACTUALLY usable, not just that the installer claimed
    # success — resolve its real path directly rather than trusting PATH.
    local pm2_bin
    pm2_bin="$(_frosty_jtg_pm2_cmd)"
    if [[ -z "$pm2_bin" ]]; then
        echo "    pm2 not found — installing directly..."
        npm install -g pm2 >/tmp/frosty_jtg_pm2_install.log 2>&1
        hash -r
        pm2_bin="$(_frosty_jtg_pm2_cmd)"
    fi
    if [[ -z "$pm2_bin" ]]; then
        _frosty_fail "pm2 setup failed — JTG Panel needs it to stay running persistently. See /tmp/frosty_jtg_pm2_install.log"
        return 1
    fi
    _frosty_ok "pm2 ready: $pm2_bin"

    echo "    Cloning JTG Panel..."
    rm -rf "$FROSTY_JTG_DIR"
    if ! timeout 120 git clone https://github.com/JishnuTheGamer/Jtg.git "$FROSTY_JTG_DIR" >/tmp/frosty_jtg_clone.log 2>&1; then
        _frosty_fail "Clone failed — see /tmp/frosty_jtg_clone.log"
        return 1
    fi
    _frosty_ok "Repository cloned to ${FROSTY_JTG_DIR}"

    cd "$FROSTY_JTG_DIR" || return 1

    echo "    Installing dependencies (npm install — this can take a few minutes)..."
    if ! timeout 600 npm install >/tmp/frosty_jtg_npm.log 2>&1; then
        _frosty_fail "npm install failed — see /tmp/frosty_jtg_npm.log"
        return 1
    fi
    _frosty_ok "Dependencies installed"

    echo "    Building the panel (npm run build)..."
    if ! timeout 300 npm run build >/tmp/frosty_jtg_build.log 2>&1; then
        _frosty_fail "Build failed — see /tmp/frosty_jtg_build.log"
        return 1
    fi
    _frosty_ok "Build complete"

    local jwt_secret
    jwt_secret="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | base64)"

    cp .env.example .env 2>/dev/null
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=\"${jwt_secret}\"|" .env
    sed -i "s|^ENABLE_DOCKER=.*|ENABLE_DOCKER=\"true\"|" .env
    sed -i "s|^DOCKER_SOCKET_PATH=.*|DOCKER_SOCKET_PATH=\"/var/run/docker.sock\"|" .env
    _frosty_ok ".env configured (JWT secret generated)"

    echo ""
    echo -e "${C_CYAN:-}== Create Admin User ==${C_RESET:-}"
    echo -e "${C_YELLOW:-}This step is interactive — follow the prompts below.${C_RESET:-}"
    npm run createuser

    echo "    Starting JTG Panel under pm2..."
    "$pm2_bin" delete jtg-panel >/dev/null 2>&1
    if [[ -f ecosystem.config.cjs ]]; then
        "$pm2_bin" start ecosystem.config.cjs >/tmp/frosty_jtg_start.log 2>&1
    else
        "$pm2_bin" start "npm" --name "jtg-panel" -- run start >/tmp/frosty_jtg_start.log 2>&1
    fi
    "$pm2_bin" save >/dev/null 2>&1

    sleep 3
    if "$pm2_bin" describe jtg-panel >/dev/null 2>&1 || "$pm2_bin" list 2>/dev/null | grep -q "jtg"; then
        local display_ip="${FROSTY_PUBLIC_IP:-$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)}"
        _frosty_ok "JTG Panel running"
        echo ""
        echo -e "    ${C_CYAN:-}Access it at:${C_RESET:-} http://${display_ip}:6767"
        echo -e "    ${C_YELLOW:-}Set up a Cloudflare Tunnel route (port 6767) or reverse proxy for HTTPS access.${C_RESET:-}"
    else
        _frosty_fail "JTG Panel did not start — check: $pm2_bin logs jtg-panel (or: cat /tmp/frosty_jtg_start.log)"
        return 1
    fi
    return 0
}

show_jtg_panel_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}           ${C_ICE}${C_BOLD}❄  J T G   P A N E L  ❄${C_RESET}            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Restart${C_RESET}                                  ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}View Logs${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[3]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  ❄ Select an option [1-3]: " jtg_choice

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_jtg_pm2_cmd)"
    case "$jtg_choice" in
        1) "$pm2_bin" restart jtg-panel; _frosty_ok "Restarted" ;;
        2) "$pm2_bin" logs jtg-panel --lines 30 --nostream ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
}

run_jtg_panel_flow() {
    if jtg_panel_installed; then
        show_jtg_panel_submenu
        return 0
    fi
    install_jtg_panel
}
