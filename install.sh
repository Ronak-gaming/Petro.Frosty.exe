cat > install.sh << 'FROSTY_EOF'
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

    set +u
    # shellcheck disable=SC1091
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
    clear
    print_banner
    detect_system

    load_module "checks.sh"
    run_safety_checks

    load_module "prepare.sh"
    install_dependencies

    if [[ "$FROSTY_CHECK_FAILED" -eq 1 ]]; then
        echo -e "${C_RED}Dependency installation failed. Aborting.${C_RESET}"
        exit 1
    fi

    load_module "php.sh"
    if ! install_php; then
        echo -e "${C_RED}PHP installation failed. Aborting.${C_RESET}"
        exit 1
    fi

    echo -e "${C_CYAN}Phase 2 Step 3 (PHP installation) complete. Ready for Step 4.${C_RESET}"
}

main "$@"
FROSTY_EOF

echo "install.sh rewritten: $(wc -l < install.sh) lines"
grep -n "php.sh\|install_php\|main \"\$@\"" install.sh
