#!/usr/bin/env bash
set -uo pipefail

_FROSTY_PM2_BIN_CACHE=""
_frosty_pm2_bin() {
    if [[ -n "$_FROSTY_PM2_BIN_CACHE" && -f "$_FROSTY_PM2_BIN_CACHE" ]]; then
        echo "$_FROSTY_PM2_BIN_CACHE"
        return 0
    fi

    hash -r 2>/dev/null
    if command -v pm2 >/dev/null 2>&1; then
        _FROSTY_PM2_BIN_CACHE="$(command -v pm2)"
        echo "$_FROSTY_PM2_BIN_CACHE"
        return 0
    fi

    local npm_global
    npm_global="$(npm root -g 2>/dev/null)"
    for candidate in \
        "${npm_global}/pm2/bin/pm2" \
        "/usr/local/lib/node_modules/pm2/bin/pm2" \
        "/usr/lib/node_modules/pm2/bin/pm2" \
        "${HOME}/.npm-global/lib/node_modules/pm2/bin/pm2"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            _FROSTY_PM2_BIN_CACHE="$candidate"
            echo "$candidate"
            return 0
        fi
    done

    echo ""
    return 1
}

_frosty_ensure_pm2() {
    if [[ -d /run/systemd/system ]]; then
        return 0
    fi

    if [[ -n "$(_frosty_pm2_bin)" ]]; then
        _frosty_ok "pm2 already installed: $("$(_frosty_pm2_bin)" -v 2>/dev/null)"
        return 0
    fi

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "    Installing Node.js LTS..."
        if curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/frosty_nodesource.sh 2>/tmp/frosty_node_install.log; then
            bash /tmp/frosty_nodesource.sh >>/tmp/frosty_node_install.log 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >>/tmp/frosty_node_install.log 2>&1
        else
            _frosty_fail "Failed to download NodeSource setup script — see /tmp/frosty_node_install.log"
            return 1
        fi

        if ! command -v node >/dev/null 2>&1; then
            _frosty_fail "Node.js installation failed — see /tmp/frosty_node_install.log"
            return 1
        fi
        _frosty_ok "Node.js installed: $(node -v)"
    else
        _frosty_ok "Node.js already present: $(node -v), npm $(npm -v)"
    fi

    echo "    Installing pm2 globally..."
    npm install -g pm2 >/tmp/frosty_pm2_install.log 2>&1
    local npm_rc=$?
    hash -r 2>/dev/null
    _FROSTY_PM2_BIN_CACHE=""

    # The real fix: don't trust npm's exit code alone — actually verify
    # pm2 is callable afterward. npm can report success while the
    # binary isn't yet resolvable in this shell, which is exactly what
    # was causing every downstream caller (Cloudflare, JTG Panel,
    # MariaDB, etc.) to silently fail after "pm2 installed" printed.
    local resolved
    resolved="$(_frosty_pm2_bin)"
    if [[ $npm_rc -eq 0 && -n "$resolved" ]]; then
        _frosty_ok "pm2 installed: $("$resolved" -v 2>/dev/null)"
    else
        _frosty_fail "pm2 install failed or isn't callable after install — see /tmp/frosty_pm2_install.log"
        return 1
    fi

    return 0
}

_frosty_pm2_start() {
    local name="$1"
    local cwd="$2"
    shift 2
    local cmd=("$@")

    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin)"
    if [[ -z "$pm2_bin" ]]; then
        _frosty_fail "pm2 not available — cannot start '$name'"
        return 1
    fi

    if "$pm2_bin" describe "$name" >/dev/null 2>&1; then
        "$pm2_bin" restart "$name" >/dev/null 2>&1
    else
        if [[ ${#cmd[@]} -gt 1 ]]; then
            "$pm2_bin" start "${cmd[0]}" --name "$name" --cwd "$cwd" -- "${cmd[@]:1}" >/dev/null 2>&1
        else
            "$pm2_bin" start "${cmd[0]}" --name "$name" --cwd "$cwd" >/dev/null 2>&1
        fi
    fi

    local waited=0
    while [[ $waited -lt 10 ]]; do
        if "$pm2_bin" describe "$name" 2>/dev/null | grep -q "online"; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    "$pm2_bin" save >/dev/null 2>&1

    if "$pm2_bin" describe "$name" 2>/dev/null | grep -q "online"; then
        _frosty_ok "'$name' running under pm2"
        return 0
    else
        _frosty_fail "'$name' failed to reach online state under pm2 — check: $pm2_bin logs $name"
        return 1
    fi
}

_frosty_pm2_status() {
    local name="$1"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin)"
    if [[ -z "$pm2_bin" ]]; then
        echo "not running (pm2 not installed)"
        return 1
    fi
    if "$pm2_bin" describe "$name" 2>/dev/null | grep -q "online"; then
        echo "online"
        return 0
    else
        echo "not running"
        return 1
    fi
}

_frosty_pm2_resurrect() {
    if [[ -d /run/systemd/system ]]; then
        return 0
    fi
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin)"
    if [[ -z "$pm2_bin" ]]; then
        return 0
    fi
    "$pm2_bin" resurrect >/dev/null 2>&1
}
