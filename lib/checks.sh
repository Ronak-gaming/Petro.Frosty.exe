#!/usr/bin/env bash
# ============================================================
# Frosty.exe - Phase 2 Step 1: Safety Checks
# ============================================================

set -uo pipefail

FROSTY_REQUIRED_COMMANDS=(
    curl wget tar gzip grep awk sed systemctl
)

FROSTY_CHECK_FAILED=0

_frosty_ok()   { echo -e "[\e[32m✓\e[0m] $1"; }
_frosty_warn() { echo -e "[\e[33m!\e[0m] $1"; }
_frosty_fail() { echo -e "[\e[31m✗\e[0m] $1"; FROSTY_CHECK_FAILED=1; }

check_root() {
    echo "== Checking privileges =="
    if [[ "${EUID}" -ne 0 ]]; then
        _frosty_fail "Not running as root. Re-run with: sudo bash install.sh"
        return 1
    fi
    _frosty_ok "Running as root"
    return 0
}

check_supported_os() {
    echo "== Checking operating system =="

    if [[ -z "${FROSTY_OS_ID:-}" || -z "${FROSTY_OS_VERSION:-}" ]]; then
        if [[ ! -f /etc/os-release ]]; then
            _frosty_fail "/etc/os-release not found — cannot determine OS"
            return 1
        fi
        set +u
        # shellcheck disable=SC1091
        source /etc/os-release
        set -u
        FROSTY_OS_ID="${ID:-unknown}"
        FROSTY_OS_VERSION="${VERSION_ID:-unknown}"
        FROSTY_OS_PRETTY="${PRETTY_NAME:-$FROSTY_OS_ID $FROSTY_OS_VERSION}"
    fi

    local supported=0
    case "${FROSTY_OS_ID}:${FROSTY_OS_VERSION}" in
        "ubuntu:20.04"|"ubuntu:22.04"|"ubuntu:24.04"|"debian:11"|"debian:12")
            supported=1
            ;;
    esac

    if [[ "$supported" -eq 1 ]]; then
        _frosty_ok "Detected supported OS: ${FROSTY_OS_PRETTY:-$FROSTY_OS_ID $FROSTY_OS_VERSION}"
        return 0
    else
        _frosty_fail "Unsupported OS: ${FROSTY_OS_PRETTY:-$FROSTY_OS_ID $FROSTY_OS_VERSION}"
        echo "    Supported: Ubuntu 20.04/22.04/24.04, Debian 11/12"
        return 1
    fi
}

check_architecture() {
    echo "== Checking architecture =="
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|aarch64)
            _frosty_ok "Architecture supported: $arch"
            return 0
            ;;
        *)
            _frosty_fail "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

check_required_commands() {
    echo "== Checking required commands =="
    local missing=()
    for cmd in "${FROSTY_REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        _frosty_ok "All required base commands present"
    else
        _frosty_warn "Missing commands (will attempt to install in Step 2): ${missing[*]}"
    fi
    return 0
}

check_environment() {
    echo "== Checking environment =="

    if [[ ! -d /run/systemd/system ]]; then
        _frosty_warn "systemd not detected as PID 1 controller — services will be supervised by pm2 instead"
    else
        _frosty_ok "systemd detected"
    fi

    local avail_kb
    avail_kb="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ -n "$avail_kb" && "$avail_kb" -lt 5242880 ]]; then
        _frosty_warn "Low disk space on / (less than 5GB free)"
    else
        _frosty_ok "Sufficient disk space available"
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt="$(systemd-detect-virt 2>/dev/null || echo "none")"
        if [[ "$virt" != "none" ]]; then
            _frosty_warn "Running inside virtualization/container: $virt"
        fi
    fi

    local pub_ip
    pub_ip="$(curl -s -4 --max-time 5 https://api.ipify.org || echo "")"
    if [[ -z "$pub_ip" ]]; then
        _frosty_warn "Could not determine public IPv4 address (may lack public networking)"
    else
        _frosty_ok "Public IPv4 detected: $pub_ip"
        export FROSTY_PUBLIC_IP="$pub_ip"
    fi

    return 0
}

run_safety_checks() {
    echo ""
    echo "❄ Frosty.exe — Running Safety Checks ❄"
    echo "----------------------------------------"

    check_root
    check_supported_os
    check_architecture
    check_required_commands
    check_environment

    echo "----------------------------------------"

    if [[ "$FROSTY_CHECK_FAILED" -eq 1 ]]; then
        echo -e "\e[31mCritical checks failed. Aborting installation.\e[0m"
        exit 1
    fi

    echo -e "\e[36mAll critical checks passed. Proceeding...\e[0m"
    echo ""
}
