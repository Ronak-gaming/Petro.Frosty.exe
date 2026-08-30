#!/usr/bin/env bash
# ============================================================
# Frosty.exe - Phase 2 Step 3: PHP Installation & Configuration
# ============================================================

set -uo pipefail

FROSTY_PHP_VERSION="8.3"

FROSTY_PHP_PACKAGES=(
    "php${FROSTY_PHP_VERSION}"
    "php${FROSTY_PHP_VERSION}-common"
    "php${FROSTY_PHP_VERSION}-cli"
    "php${FROSTY_PHP_VERSION}-gd"
    "php${FROSTY_PHP_VERSION}-mysql"
    "php${FROSTY_PHP_VERSION}-mbstring"
    "php${FROSTY_PHP_VERSION}-bcmath"
    "php${FROSTY_PHP_VERSION}-xml"
    "php${FROSTY_PHP_VERSION}-fpm"
    "php${FROSTY_PHP_VERSION}-curl"
    "php${FROSTY_PHP_VERSION}-zip"
    "php${FROSTY_PHP_VERSION}-tokenizer"
    "php${FROSTY_PHP_VERSION}-intl"
)

FROSTY_PHP_REQUIRED_EXT=(
    json mbstring pdo pdo_mysql posix zip curl gd xml bcmath tokenizer intl
)

_frosty_add_php_ppa() {
    echo "    Adding PHP repository (ppa:ondrej/php)..."

    if ! dpkg -s software-properties-common >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common >/tmp/frosty_php_ppa.log 2>&1
    fi

    if grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        _frosty_ok "PHP PPA already added"
        return 0
    fi

    if LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php >>/tmp/frosty_php_ppa.log 2>&1; then
        _frosty_ok "PHP PPA added"
    else
        _frosty_fail "Failed to add PHP PPA — see /tmp/frosty_php_ppa.log"
        return 1
    fi

    if DEBIAN_FRONTEND=noninteractive apt-get update -y >>/tmp/frosty_php_ppa.log 2>&1; then
        return 0
    else
        _frosty_fail "apt-get update after adding PPA failed — see /tmp/frosty_php_ppa.log"
        return 1
    fi
}

install_php() {
    echo ""
    echo "== Installing PHP ${FROSTY_PHP_VERSION} =="

    if command -v "php${FROSTY_PHP_VERSION}" >/dev/null 2>&1; then
        local current_ver
        current_ver="$(php${FROSTY_PHP_VERSION} -v 2>/dev/null | head -1)"
        _frosty_ok "PHP ${FROSTY_PHP_VERSION} already present: $current_ver"
    else
        if ! _frosty_add_php_ppa; then
            return 1
        fi

        echo "    Installing PHP ${FROSTY_PHP_VERSION} and extensions..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${FROSTY_PHP_PACKAGES[@]}" >/tmp/frosty_php_install.log 2>&1; then
            _frosty_ok "PHP ${FROSTY_PHP_VERSION} installed"
        else
            _frosty_fail "PHP installation failed — see /tmp/frosty_php_install.log"
            return 1
        fi
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable "php${FROSTY_PHP_VERSION}-fpm" >/dev/null 2>&1
        systemctl restart "php${FROSTY_PHP_VERSION}-fpm" >/dev/null 2>&1

        if systemctl is-active --quiet "php${FROSTY_PHP_VERSION}-fpm"; then
            _frosty_ok "php${FROSTY_PHP_VERSION}-fpm running"
        else
            _frosty_fail "php${FROSTY_PHP_VERSION}-fpm failed to start"
            systemctl status "php${FROSTY_PHP_VERSION}-fpm" --no-pager | tail -20
            return 1
        fi
    else
        local fpm_sock="/run/php/php${FROSTY_PHP_VERSION}-fpm.sock"
        local fpm_pid="/run/php/php${FROSTY_PHP_VERSION}-fpm.pid"
        local fpm_syslog="/var/log/php${FROSTY_PHP_VERSION}-fpm.log"
        # The real process title is "php-fpm: master process (<conf path>)"
        # with NO version number next to "master" — only the conf path
        # (which contains the version) distinguishes it. Match on that.
        local fpm_pattern="master process \\(.*php/${FROSTY_PHP_VERSION}/fpm/php-fpm\\.conf\\)"

        if [[ -S "$fpm_sock" ]] && pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
            _frosty_ok "php-fpm${FROSTY_PHP_VERSION} already running (socket active)"
           else
        _frosty_warn "No systemd — starting php-fpm${FROSTY_PHP_VERSION} manually"
        mkdir -p /run/php

            # This config has no PID file, so php-fpm has no way to detect
            # an existing instance — deleting just the socket file (without
            # killing the process behind it) orphans the old master, which
            # keeps running invisibly and piles up with every restart.
            # Always kill any existing master for this version first.
            if pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
                _frosty_warn "Found existing php-fpm${FROSTY_PHP_VERSION} master process(es) — stopping before restart"
                pkill -f "$fpm_pattern" 2>/dev/null
                sleep 1
                pkill -9 -f "$fpm_pattern" 2>/dev/null
            fi
            rm -f "$fpm_sock" "$fpm_pid"

            "php-fpm${FROSTY_PHP_VERSION}" -D >/tmp/frosty_php_fpm.log 2>&1
            sleep 2

            if [[ -S "$fpm_sock" ]] && pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
                _frosty_ok "php-fpm${FROSTY_PHP_VERSION} running (socket active)"
            else
                # php-fpm -D detaches from the terminal right after forking,
                # so real startup errors usually never reach our redirected
                # log — they go to php-fpm's own configured error log
                # instead. Pull both, plus a config test, so the actual
                # cause is visible.
                _frosty_fail "php-fpm${FROSTY_PHP_VERSION} failed to start"
                echo "    -- config test (php-fpm${FROSTY_PHP_VERSION} -t) --"
                "php-fpm${FROSTY_PHP_VERSION}" -t 2>&1 | sed 's/^/    /'
                if [[ -f "$fpm_syslog" ]]; then
                    echo "    -- last lines of ${fpm_syslog} --"
                    tail -15 "$fpm_syslog" 2>/dev/null | sed 's/^/    /'
                fi
                if [[ -s /tmp/frosty_php_fpm.log ]]; then
                    echo "    -- /tmp/frosty_php_fpm.log --"
                    cat /tmp/frosty_php_fpm.log | sed 's/^/    /'
                fi
                return 1
            fi
        fi
    fi

local missing_ext=()
    for ext in "${FROSTY_PHP_REQUIRED_EXT[@]}"; do
        if ! "php${FROSTY_PHP_VERSION}" -m 2>/dev/null | grep -qi "^${ext}$"; then
            missing_ext+=("$ext")
        fi
    done

    if [[ ${#missing_ext[@]} -gt 0 ]]; then
        _frosty_warn "Missing PHP extensions detected: ${missing_ext[*]} — reinstalling explicitly"
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_php_ext_retry.log 2>&1
        local ext_pkgs=()
        for ext in "${missing_ext[@]}"; do
            ext_pkgs+=("php${FROSTY_PHP_VERSION}-${ext}")
        done
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${ext_pkgs[@]}" >>/tmp/frosty_php_ext_retry.log 2>&1

        missing_ext=()
        for ext in "${FROSTY_PHP_REQUIRED_EXT[@]}"; do
            if ! "php${FROSTY_PHP_VERSION}" -m 2>/dev/null | grep -qi "^${ext}$"; then
                missing_ext+=("$ext")
            fi
        done
    fi

    if [[ ${#missing_ext[@]} -eq 0 ]]; then
        _frosty_ok "All required PHP extensions loaded"
    else
        _frosty_fail "Missing PHP extensions after retry: ${missing_ext[*]} — see /tmp/frosty_php_ext_retry.log"
        return 1
    fi

    export FROSTY_PHP_VERSION
    return 0
}
