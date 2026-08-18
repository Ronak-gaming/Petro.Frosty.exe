#!/usr/bin/env bash
set -uo pipefail

specs_checker() {
    echo ""
    echo -e "${C_CYAN:-}== Specs Checker ==${C_RESET:-}"
    echo ""

    echo "    Updating and upgrading system..."
    apt update -y >/tmp/frosty_specs_apt.log 2>&1
    apt upgrade -y >>/tmp/frosty_specs_apt.log 2>&1
    _frosty_ok "System updated"

    echo "    Installing fetch tool..."
    if apt-cache show neofetch >/dev/null 2>&1; then
        apt install -y neofetch >>/tmp/frosty_specs_apt.log 2>&1
    elif apt-cache show screenfetch >/dev/null 2>&1; then
        apt install -y screenfetch >>/tmp/frosty_specs_apt.log 2>&1
    fi

    echo ""
    if command -v neofetch >/dev/null 2>&1; then
        neofetch
    elif command -v screenfetch >/dev/null 2>&1; then
        screenfetch
    else
        _frosty_warn "Neither neofetch nor screenfetch could be installed"
    fi

    echo ""
    echo -e "${C_CYAN:-}== Real Resource Limits (cgroup) ==${C_RESET:-}"
    echo ""

    echo -e "${C_WHITE:-}-- Memory --${C_RESET:-}"
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        local mem_max
        mem_max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
        if [[ "$mem_max" == "max" ]]; then
            echo "  cgroup v2 memory.max: unlimited (host-level)"
        else
            echo "  cgroup v2 memory.max: $((mem_max / 1024 / 1024)) MB"
        fi
    elif [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        local mem_limit
        mem_limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
        echo "  cgroup v1 memory.limit_in_bytes: $((mem_limit / 1024 / 1024)) MB"
    else
        echo "  No cgroup memory limit file found"
    fi
    echo "  OS-reported (free -h):"
    free -h | sed 's/^/    /'

    echo ""
    echo -e "${C_WHITE:-}-- CPU --${C_RESET:-}"
    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        local cpu_max
        cpu_max="$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
        echo "  cgroup v2 cpu.max: $cpu_max"
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)"
        echo "  cgroup v1 cfs_quota_us/cfs_period_us: ${quota}/${period}"
    else
        echo "  No cgroup CPU limit file found"
    fi
    echo "  OS-reported cores (nproc): $(nproc)"

    echo ""
    echo -e "${C_WHITE:-}-- Disk --${C_RESET:-}"
    df -h / | sed 's/^/    /'

    echo ""
    echo -e "${C_WHITE:-}-- Virtualization --${C_RESET:-}"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        echo "  Detected: $(systemd-detect-virt 2>/dev/null || echo 'none/bare-metal')"
    else
        echo "  systemd-detect-virt not available"
    fi
    echo "  /dev/kvm present: $([[ -e /dev/kvm ]] && echo yes || echo no)"

    return 0
}

show_toolbox_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄  T O O L B O X  ❄${C_RESET}                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Cloudflare${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[2]${C_RESET} ${C_WHITE}Specs Checker${C_RESET}                            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[3]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-3]: " tb_choice

    case "$tb_choice" in
        1) load_module "cloudflare.sh"; run_cloudflare_flow ;;
        2) specs_checker ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_toolbox_menu
}
