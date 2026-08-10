#!/usr/bin/env bash
# ============================================================
# Frosty.exe — All-in-One Pterodactyl Installer
# Repo: https://github.com/Ronak-gaming/Petro.Frosty.exe
# ============================================================

set -uo pipefail

FROSTY_RAW_BASE="https://raw.githubusercontent.com/Ronak-gaming/Petro.Frosty.exe/main"

# ---- Colors ----
C_CYAN='\e[36m'
C_BLUE='\e[34m'
C_BOLD='\e[1m'
C_RESET='\e[0m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_RED='\e[31m'

# ---- Load lib modules (works both locally and via curl|bash) ----
load_module() {
    local name="$1"
    if [[ -f "./lib/${name}" ]]; then
        # shellcheck disable=SC1090
        source "./lib/${name}"
    else
        # shellcheck disable=SC1090
        source <(curl -fsSL "${FROSTY_RAW_BASE}/lib/${name}")
    fi
}

# ---- Banner ----
print_banner() {
    echo -e "${C_CYAN}${C_BOLD}"
    cat << "EOF"
╔══════════════════════════════════════════════╗
║                                                ║
║          ❄  F R O S T Y . E X E  ❄           ║
║                                                ║
║          ❄  ALL-IN-ONE INSTALLER  ❄          ║
║                                                ║
║       ❄  ❄  ❄  ❄  ❄  ❄  ❄  ❄               ║
║                                                ║
╚══════════════════════════════════════════════╝
EOF
    echo -e "${C_RESET}"
}

# ---- Simple loading/flicker animation ----
frosty_spinner() {
    local msg="$1"
    local pid=$2
    local frames=("❄" "❅" "❆" "❅")
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${C_BLUE}%s${C_RESET} %s   " "${frames[$((i % 4))]}" "$msg"
        i=$((i+1))
        sleep 0.15
    done
    printf "\r${C_GREEN}✓${C_RESET} %s   \n" "$msg"
    tput cnorm 2>/dev/null || true
}

# ---- System detection (Phase 1 Step 5) ----
detect_system() {
    echo -e "${C_CYAN}== System Detection ==${C_RESET}"

    # shellcheck disable=SC1091
    source /etc/os-release 2>/dev/null || true

    FROSTY_OS_NAME="${PRETTY_NAME:-Unknown}"
    FROSTY_CPU_CORES="$(nproc 2>/dev/null || echo "unknown")"
    FROSTY_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
    FROSTY_DISK_FREE="$(df -h / 2>/dev/null | awk 'NR==2{print $4}')"
    FROSTY_ARCH="$(uname -m)"
    FROSTY_KERNEL="$(uname -r)"
    FROSTY_IPV4="$(curl -s -4 --max-time 5 https://api.ipify.org || echo "unknown")"

    echo "  OS:           $FROSTY_OS_NAME"
    echo "  Architecture: $FROSTY_ARCH"
    echo "  Kernel:       $FROSTY_KERNEL"
    echo "  CPU Cores:    $FROSTY_CPU_CORES"
    echo "  RAM:          ${FROSTY_RAM_MB:-unknown} MB"
    echo "  Disk Free:    ${FROSTY_DISK_FREE:-unknown}"
    echo "  IPv4:         $FROSTY_IPV4"
    echo ""
}

# ---- Main ----
main() {
    clear
    print_banner
    detect_system

    load_module "checks.sh"
    run_safety_checks

    echo -e "${C_CYAN}Frosty.exe foundation checks complete.${C_RESET}"
    echo -e "${C_CYAN}Phase 2 Step 1 (safety checks) passed. Ready for Step 2.${C_RESET}"
}

main "$@"
