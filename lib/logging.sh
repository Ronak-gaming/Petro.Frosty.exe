#!/usr/bin/env bash
set -uo pipefail

FROSTY_LOG_DIR="/var/log/frosty"
FROSTY_LOG_FILE="${FROSTY_LOG_DIR}/frosty.log"
mkdir -p "$FROSTY_LOG_DIR" 2>/dev/null

_frosty_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" >> "$FROSTY_LOG_FILE" 2>/dev/null
}

_frosty_ok() {
    echo -e "[\e[32m✓\e[0m] $1"
    _frosty_log "OK" "$1"
}

_frosty_warn() {
    echo -e "[\e[33m!\e[0m] $1"
    _frosty_log "WARN" "$1"
}

_frosty_fail() {
    echo -e "[\e[31m✗\e[0m] $1"
    _frosty_log "FAIL" "$1"
    FROSTY_CHECK_FAILED=1
}

_frosty_info() {
    echo "    $1"
    _frosty_log "INFO" "$1"
}

# Run a command, log its outcome, return its exit code
frosty_run() {
    local desc="$1"; shift
    local logfile="${FROSTY_LOG_DIR}/$(echo "$desc" | tr ' /' '__').log"
    if "$@" >"$logfile" 2>&1; then
        _frosty_log "OK" "$desc (log: $logfile)"
        return 0
    else
        local code=$?
        _frosty_log "FAIL" "$desc failed (exit $code, log: $logfile)"
        return $code
    fi
}

frosty_service_status() {
    local svc="$1"
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$svc" 2>/dev/null && echo "running" || echo "stopped"
    else
        pgrep -f "$svc" >/dev/null 2>&1 && echo "running" || echo "stopped"
    fi
}

frosty_diagnostics_summary() {
    echo ""
    echo -e "${C_CYAN:-}== Frosty Diagnostics Summary ==${C_RESET:-}"
    printf "  %-15s %s\n" "MariaDB:" "$(mysqladmin ping >/dev/null 2>&1 && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "Redis:" "$(redis-cli ping 2>/dev/null | grep -q PONG && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "Docker:" "$(docker info >/dev/null 2>&1 && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "PHP-FPM:" "$([[ -S "/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.sock" ]] && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "Nginx:" "$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null | grep -qv 000 && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "Wings:" "$(pgrep -f '^/usr/local/bin/wings' >/dev/null 2>&1 && echo OK || echo DOWN)"
    printf "  %-15s %s\n" "Cloudflare:" "$(pgrep -f 'cloudflared tunnel run' >/dev/null 2>&1 && echo OK || echo DOWN)"
    echo ""
    echo "  Full log: $FROSTY_LOG_FILE"
}
