#!/usr/bin/env bash
# ============================================================
# Frosty.exe — All-in-One Pterodactyl Installer
# Repo: https://github.com/Ronak-gaming/Petro.Frosty.exe
# ============================================================

set -uo pipefail

# Ensure /usr/local/bin and sbin directories are ALWAYS on PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

FROSTY_RAW_BASE="https://raw.githubusercontent.com/Ronak-gaming/Petro.Frosty.exe/main"
FROSTY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"

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

# ---- Load lib modules (works locally, in /opt/frosty, and via curl|bash) ----
load_module() {
    local name="$1"
    if [[ -f "${FROSTY_SCRIPT_DIR}/lib/${name}" ]]; then
        source "${FROSTY_SCRIPT_DIR}/lib/${name}"
    elif [[ -f "/opt/frosty/lib/${name}" ]]; then
        source "/opt/frosty/lib/${name}"
    elif [[ -f "./lib/${name}" ]]; then
        source "./lib/${name}"
    else
        local tmp_mod
        tmp_mod="$(mktemp /tmp/frosty_mod_XXXXXXXX)"
        if curl -fsSL "${FROSTY_RAW_BASE}/lib/${name}?t=$(date +%s)" -o "$tmp_mod" 2>/dev/null && [[ -s "$tmp_mod" ]]; then
            sed -i 's/\xc2\xa0/ /g; s/\r$//' "$tmp_mod" 2>/dev/null || true
            source "$tmp_mod"
            rm -f "$tmp_mod"
        else
            rm -f "$tmp_mod"
            echo -e "${C_RED}[✗] Failed to load module: ${name}${C_RESET}"
            return 1
        fi
    fi
}

# ---- UI helpers ----
# visible length of a string that may contain colour escapes
_frosty_vlen() { printf '%b' "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | LC_ALL=C.UTF-8 wc -m | tr -d ' '; }
# centre text (colour escapes allowed) in a field of $2 visible columns
_frosty_center() {
    local t="$1" w="$2" len l r
    len="$(_frosty_vlen "$t")"; (( len > w )) && len=$w
    l=$(( (w - len) / 2 )); r=$(( w - len - l ))
    printf '%*s%b%*s' "$l" '' "$t" "$r" ''
}
# horizontal rule: $1 = length, $2 = character
_frosty_rule() {
    local n="$1" ch="${2:-─}" s
    (( n < 0 )) && n=0
    printf -v s '%*s' "$n" ''
    printf '%s' "${s// /$ch}"
}

# ---- Banner (compact; the full block-letter screen lives in lib/menu.sh) ----
print_banner() {
    local F="${C_CYAN}${C_BOLD}" R="${C_RESET}"
    echo -e "${F}┏$(_frosty_rule 48 ━)┓${R}"
    echo -e "${F}┃${R}$(_frosty_center "${C_ICE}${C_BOLD}❄${R}  ${C_WHITE}${C_BOLD}F R O S T Y Y   I N S T A L L E R${R}  ${C_ICE}${C_BOLD}❄${R}" 48)${F}┃${R}"
    echo -e "${F}┃${R}$(_frosty_center "${C_CYAN}${C_BOLD}»»»${R} ${C_BLUE}${C_BOLD}A L L - I N - O N E${R} ${C_CYAN}${C_BOLD}«««${R}" 48)${F}┃${R}"
    echo -e "${F}┗$(_frosty_rule 48 ━)┛${R}"
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
    FROSTY_IPV4="$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$FROSTY_IPV4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        export FROSTY_PUBLIC_IP="$FROSTY_IPV4"
    else
        FROSTY_IPV4="unknown"
        FROSTY_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
        export FROSTY_PUBLIC_IP
    fi

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
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${C_RED}[✗] Run as root: sudo bash install.sh${C_RESET}"
        exit 1
    fi
    load_module "logging.sh"
    load_module "checks.sh"
    load_module "menu.sh"
    show_main_menu
}

main "$@"
