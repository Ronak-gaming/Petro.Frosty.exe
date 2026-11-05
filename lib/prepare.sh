#!/usr/bin/env bash
# ============================================================
# Frosty.exe - Phase 2 Step 2: System Package Preparation
# ============================================================

set -uo pipefail

FROSTY_BASE_PACKAGES=(
    curl
    wget
    tar
    gzip
    grep
    gawk
    sed
    ca-certificates
    gnupg
    lsb-release
    software-properties-common
    apt-transport-https
    unzip
    cron
)

_frosty_apt_updated=0

_frosty_apt_update_once() {
    if [[ "$_frosty_apt_updated" -eq 0 ]]; then
        echo "    Updating package index..."
        if DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_apt_update.log 2>&1; then
            _frosty_apt_updated=1
        else
            _frosty_fail "apt-get update failed — see /tmp/frosty_apt_update.log"
            return 1
        fi
    fi
    return 0
}

install_dependencies() {
    echo ""
    echo "== Installing base dependencies =="

    # Repair broken/mismatched/interrupted package state before attempting anything
    dpkg --configure -a >/tmp/frosty_apt_fixbroken.log 2>&1
    if ! DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y >>/tmp/frosty_apt_fixbroken.log 2>&1; then
        _frosty_warn "apt --fix-broken install reported issues — see /tmp/frosty_apt_fixbroken.log (continuing anyway)"
    fi

    if ! _frosty_apt_update_once; then
        return 1
    fi

    local to_install=()
    for pkg in "${FROSTY_BASE_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        _frosty_ok "All base packages already installed"
        return 0
    fi

    echo "    Installing: ${to_install[*]}"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" >/tmp/frosty_apt_install.log 2>&1; then
        _frosty_ok "Base packages installed successfully"
    else
        _frosty_warn "First install attempt failed — running dpkg repair and retrying once..."
        dpkg --configure -a >>/tmp/frosty_apt_install.log 2>&1
        DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y >>/tmp/frosty_apt_install.log 2>&1
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" >>/tmp/frosty_apt_install.log 2>&1; then
            _frosty_ok "Base packages installed successfully (after retry)"
        else
            _frosty_fail "Package installation failed after retry — see /tmp/frosty_apt_install.log"
            return 1
        fi
    fi

    local still_missing=()
    for cmd in "${FROSTY_REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            still_missing+=("$cmd")
        fi
    done

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        _frosty_fail "Still missing after install: ${still_missing[*]}"
        return 1
    fi

    _frosty_ok "All required commands now available"
    return 0
}
