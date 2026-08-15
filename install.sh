#!/usr/bin/env bash
# ============================================================
# Frosty.exe — All-in-One Pterodactyl Installer
# Repo: https://github.com/Ronak-gaming/Petro.Frosty.exe
# ============================================================

set -uo pipefail

FROSTY_RAW_BASE="https://raw.githubusercontent.com/Ronak-gaming/Petro.Frosty.exe/main"
FROSTY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Colors ----
C_CYAN='\e[38;5;51m'
C_ICE='\e[38;5;159m'
C_FROST='\e[38;5;123m'
C_BLUE='\e[38;5;33m'
C_PURPLE='\e[38;5;111m'
C_BOLD='\e[1m'
C_RESET='\e[0m'
C_GREEN='\e[38;5;46m'
C_YELLOW='\e[38;5;220m'
C_RED='\e[38;5;196m'
C_WHITE='\e[38;5;255m'

# ---- Load lib modules (works both locally and via curl|bash) ----
load_module() {
    local name="$1"
    if [[ -f "${FROSTY_SCRIPT_DIR}/lib/${name}" ]]; then
        source "${FROSTY_SCRIPT_DIR}/lib/${name}"
    else
        source <(curl -fsSL "${FROSTY_RAW_BASE}/lib/${name}")
    fi
}

# ---- Banner ----
print_banner() {
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄${C_RESET}  ${C_WHITE}${C_BOLD}F R O S T Y . E X E${C_RESET}  ${C_ICE}${C_BOLD}❄${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_PURPLE}${C_BOLD}❄  ALL-IN-ONE INSTALLER  ❄${C_RESET}          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}      ${C_CYAN}❄${C_RESET} ${C_ICE}❄${C_RESET} ${C_BLUE}❄${C_RESET} ${C_PURPLE}❄${C_RESET} ${C_CYAN}❄${C_RESET} ${C_ICE}❄${C_RESET} ${C_BLUE}❄${C_RESET} ${C_PURPLE}❄${C_RESET}      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}      ${C_WHITE}Created and maintained by Ronak Gaming${C_RESET}     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
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

    set +u
    source /etc/os-release 2>/dev/null || true
    set -u

    FROSTY_OS_ID="${ID:-unknown}"
    FROSTY_OS_VERSION="${VERSION_ID:-unknown}"
    FROSTY_OS_PRETTY="${PRETTY_NAME:-Unknown}"
    FROSTY_OS_NAME="$FROSTY_OS_PRETTY"
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
    load_module "logging.sh"
    load_module "checks.sh"
    load_module "menu.sh"
    show_main_menu
}

main "$@"
