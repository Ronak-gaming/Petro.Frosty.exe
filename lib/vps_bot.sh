#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPSBOT_DIR="/opt/Frosty-vps-bot"

vps_bot_installed() {
    [[ -f "${FROSTY_VPSBOT_DIR}/main.py" ]]
}

install_vps_bot() {
    echo ""
    echo -e "${C_CYAN:-}== Installing VPS Discord Bot ==${C_RESET:-}"

    echo "    Installing base requirements..."
    dpkg --configure -a >/tmp/frosty_vpsbot_dpkg.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_vpsbot_apt.log 2>&1
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y git nano python3 python3-pip python3-venv >>/tmp/frosty_vpsbot_apt.log 2>&1; then
        _frosty_fail "Base package install failed — see /tmp/frosty_vpsbot_apt.log"
        return 1
    fi
    _frosty_ok "git/python3/venv installed"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "    Installing Docker (the bot manages VPS containers via it)..."
        load_module "docker.sh"
        if ! install_docker; then
            _frosty_fail "Docker install failed — the bot needs it to create/manage VPS containers"
            return 1
        fi
    else
        _frosty_ok "Docker already available"
    fi

    # If it's already cloned, wipe it and start clean rather than trying
    # to reconcile a possibly-half-updated checkout.
    if [[ -d "$FROSTY_VPSBOT_DIR" ]]; then
        _frosty_warn "Existing clone found — deleting and re-cloning fresh"
        load_module "pm2.sh"
        local pm2_bin
        pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" delete vps-bot >/dev/null 2>&1
        rm -rf "$FROSTY_VPSBOT_DIR"
    fi

    echo "    Cloning Frosty-vps-bot..."
    if ! timeout 60 git clone https://github.com/Ronak-gaming/Frosty-vps-bot.git "$FROSTY_VPSBOT_DIR" >/tmp/frosty_vpsbot_clone.log 2>&1; then
        _frosty_fail "Clone failed — see /tmp/frosty_vpsbot_clone.log"
        return 1
    fi
    _frosty_ok "Cloned to ${FROSTY_VPSBOT_DIR}"

    cd "$FROSTY_VPSBOT_DIR" || return 1
    for f in main.py config.py storage.py docker_utils.py views.py; do
        if [[ ! -f "$f" ]]; then
            _frosty_warn "Expected file missing after clone: $f — bot may not run correctly"
        fi
    done

    echo "    Setting up Python virtual environment..."
    python3 -m venv venv >/tmp/frosty_vpsbot_venv.log 2>&1
    if ! ./venv/bin/pip install -U discord.py >>/tmp/frosty_vpsbot_venv.log 2>&1; then
        _frosty_fail "pip install discord.py failed — see /tmp/frosty_vpsbot_venv.log"
        return 1
    fi
    _frosty_ok "Virtual environment ready"

    echo ""
    echo -e "${C_CYAN:-}== Bot Configuration ==${C_RESET:-}"
    read -rp "  Your Discord user ID (MAIN_ADMIN_ID): " admin_id
    if [[ -z "$admin_id" || ! "$admin_id" =~ ^[0-9]+$ ]]; then
        _frosty_fail "Admin ID must be numeric (right-click your Discord profile -> Copy User ID)"
        return 1
    fi
    read -rsp "  Bot token (from Discord Developer Portal -> Bot -> Token): " bot_token
    echo ""
    if [[ -z "$bot_token" ]]; then
        _frosty_fail "Token is required"
        return 1
    fi

    if [[ -f config.py ]] && grep -q "MAIN_ADMIN_ID" config.py; then
        sed -i "s/MAIN_ADMIN_ID[[:space:]]*=.*/MAIN_ADMIN_ID = ${admin_id}/" config.py
        _frosty_ok "MAIN_ADMIN_ID written to config.py"
    else
        _frosty_warn "config.py doesn't have a MAIN_ADMIN_ID line to fill in — check it manually"
    fi

    # The token isn't hardcoded into config.py (matches how the bot is
    # documented to run — via DISCORD_BOT_TOKEN env var) — instead it's
    # written into a small start wrapper that pm2 runs, so it's set
    # automatically every time the bot starts without needing to export
    # it by hand each session.
    cat > "${FROSTY_VPSBOT_DIR}/start.sh" << STARTEOF
#!/usr/bin/env bash
cd "${FROSTY_VPSBOT_DIR}"
export DISCORD_BOT_TOKEN="${bot_token}"
source venv/bin/activate
exec python3 main.py
STARTEOF
    chmod +x "${FROSTY_VPSBOT_DIR}/start.sh"
    chmod 600 "${FROSTY_VPSBOT_DIR}/start.sh"
    _frosty_ok "Token configured (stored in start.sh, permissions locked to root-only)"

    echo "    Starting the bot under pm2..."
    load_module "pm2.sh"
    if ! _frosty_ensure_pm2_always; then
        _frosty_fail "pm2 setup failed — cannot start the bot persistently"
        return 1
    fi
    if ! _frosty_pm2_start "vps-bot" "$FROSTY_VPSBOT_DIR" "bash" "start.sh"; then
        echo "    pm2 logs:"
        local pm2_bin
        pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 20 --nostream 2>/dev/null
        return 1
    fi

    _frosty_ok "VPS Discord bot running. Try !help in your server."
    return 0
}

show_vps_bot_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}           ${C_ICE}${C_BOLD}❄  V P S   B O T  ❄${C_RESET}                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Install / Reinstall${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Restart${C_RESET}                                  ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[3]${C_RESET} ${C_WHITE}View Logs${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[4]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  ❄ Select an option [1-4]: " bot_choice

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    case "$bot_choice" in
        1) install_vps_bot ;;
        2) [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot && _frosty_ok "Restarted" || _frosty_fail "pm2 not found" ;;
        3) [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 30 --nostream || _frosty_fail "pm2 not found" ;;
        4) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
}

run_vps_bot_flow() {
    show_vps_bot_submenu
}
