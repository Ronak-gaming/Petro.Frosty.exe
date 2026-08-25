#!/usr/bin/env bash
set -uo pipefail

FROSTY_CF_MARKER="${HOME}/.frosty_cloudflare_configured"

install_cloudflared() {
    echo ""
    echo "== Installing cloudflared =="

    if command -v cloudflared >/dev/null 2>&1; then
        _frosty_ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -1)"
        return 0
    fi

    local arch cf_arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) cf_arch="amd64" ;;
        aarch64) cf_arch="arm64" ;;
        *) _frosty_fail "Unsupported architecture for cloudflared: $arch"; return 1 ;;
    esac

    echo "    Downloading cloudflared (${cf_arch})..."
    if curl -Lo /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" \
        >/tmp/frosty_cloudflared_download.log 2>&1; then
        chmod +x /usr/local/bin/cloudflared
        _frosty_ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1)"
    else
        _frosty_fail "cloudflared download failed — see /tmp/frosty_cloudflared_download.log"
        return 1
    fi

    return 0
}

connect_cloudflare_token() {
    echo ""
    echo -e "${C_CYAN:-}== Connect Cloudflare Tunnel (Token) ==${C_RESET:-}"
    echo ""
    echo "  Steps to get your token:"
    echo "    1. Go to https://one.dash.cloudflare.com/ -> Networks -> Tunnels"
    echo "    2. Click 'Create a tunnel' -> choose 'Cloudflared'"
    echo "    3. Name it (e.g. frosty-panel), click Save"
    echo "    4. On the install step, copy ONLY the long token string"
    echo "       (the part after '--token' in the command shown)"
    echo "    5. Paste it below"
    echo ""
    read -rp "  Paste your Cloudflare Tunnel token: " cf_token

    if [[ -z "$cf_token" ]]; then
        _frosty_fail "No token entered"
        return 1
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl stop cloudflared >/dev/null 2>&1
        cloudflared service uninstall >/dev/null 2>&1
    else
        pkill -f "cloudflared tunnel run" >/dev/null 2>&1
    fi

    echo "    Installing tunnel service..."
    if [[ -d /run/systemd/system ]]; then
        cloudflared service install "$cf_token" >/tmp/frosty_cf_install.log 2>&1
        systemctl enable cloudflared >/dev/null 2>&1
        systemctl restart cloudflared >/dev/null 2>&1
        sleep 3

        if systemctl is-active --quiet cloudflared; then
            _frosty_ok "Cloudflare tunnel connected and running (systemd)"
        else
            _frosty_warn "systemd service failed to start — checking why..."
            journalctl -xeu cloudflared.service --no-pager 2>/dev/null | tail -15

            echo "    Falling back to direct background process..."
            systemctl stop cloudflared >/dev/null 2>&1
            systemctl disable cloudflared >/dev/null 2>&1
            pkill -f "cloudflared tunnel run" >/dev/null 2>&1
            nohup cloudflared tunnel run --token "$cf_token" >/tmp/frosty_cf_run.log 2>&1 &
            disown
            sleep 4

            if pgrep -f "cloudflared tunnel run" >/dev/null 2>&1; then
                _frosty_ok "Cloudflare tunnel connected via background process (systemd unavailable/failed)"
            else
                _frosty_fail "Both systemd and background start failed — see /tmp/frosty_cf_install.log and /tmp/frosty_cf_run.log"
                return 1
            fi
        fi
    else
        _frosty_warn "No systemd — running tunnel manually in background"
        nohup cloudflared tunnel run --token "$cf_token" >/tmp/frosty_cf_run.log 2>&1 &
        sleep 3
        if pgrep -f "cloudflared tunnel run" >/dev/null 2>&1; then
            _frosty_ok "Cloudflare tunnel running (background process)"
        else
            _frosty_fail "Tunnel failed to start — see /tmp/frosty_cf_run.log"
            return 1
        fi
    fi

    echo "$cf_token" > "$FROSTY_CF_MARKER"
    chmod 600 "$FROSTY_CF_MARKER"

    echo ""
    echo -e "    ${C_CYAN:-}Tunnel connected. Now go to your Cloudflare Tunnel dashboard,${C_RESET:-}"
    echo -e "    ${C_CYAN:-}open the 'Public Hostname' tab, and add a route:${C_RESET:-}"
    echo -e "    ${C_CYAN:-}  Subdomain/domain -> your choice   Service -> http://localhost:80${C_RESET:-}"
    echo -e "    ${C_YELLOW:-}That step is done entirely on Cloudflare's website, not here.${C_RESET:-}"

    return 0
}

cloudflare_status() {
    echo ""
    echo "== Cloudflare Tunnel Status =="
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cloudflared 2>/dev/null; then
        _frosty_ok "Tunnel is running"
    elif pgrep -f "cloudflared tunnel run" >/dev/null 2>&1; then
        _frosty_ok "Tunnel is running"
    else
        _frosty_warn "Tunnel does not appear to be running"
    fi
}

cloudflare_remove() {
    echo ""
    echo -e "${C_RED}== Remove Cloudflare Tunnel ==${C_RESET}"
    read -rp "  Type REMOVE to confirm: " confirm
    if [[ "$confirm" != "REMOVE" ]]; then
        echo "Cancelled."
        return 1
    fi

    pkill -f "cloudflared tunnel run" >/dev/null 2>&1
    if [[ -d /run/systemd/system ]]; then
        systemctl stop cloudflared >/dev/null 2>&1
        systemctl disable cloudflared >/dev/null 2>&1
        cloudflared service uninstall >/dev/null 2>&1
    fi

    rm -f "$FROSTY_CF_MARKER"
    _frosty_ok "Cloudflare tunnel removed from this server"
    echo -e "    ${C_YELLOW:-}Note: delete the tunnel itself in the Cloudflare dashboard too, if desired.${C_RESET:-}"
    return 0
}

cloudflare_configured() {
    [[ -f "$FROSTY_CF_MARKER" ]]
}

show_cloudflare_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}      ${C_ICE}${C_BOLD}❄  C L O U D F L A R E  ❄${C_RESET}               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Status${C_RESET}                                   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Reconnect with New Token${C_RESET}                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[3]${C_RESET} ${C_WHITE}Remove Tunnel${C_RESET}                            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[4]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-4]: " sub_choice

    case "$sub_choice" in
        1) cloudflare_status ;;
        2) connect_cloudflare_token ;;
        3) cloudflare_remove ;;
        4) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
}
