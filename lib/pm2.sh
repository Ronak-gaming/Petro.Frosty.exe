#!/usr/bin/env bash
set -uo pipefail

# Ensures Node.js, npm, and pm2 are available for process supervision
# on hosts without real systemd. No-ops entirely on real systemd hosts,
# since those already get proper .service files elsewhere.
_frosty_ensure_pm2() {
    if [[ -d /run/systemd/system ]]; then
        return 0
    fi

    if command -v pm2 >/dev/null 2>&1; then
        _frosty_ok "pm2 already installed: $(pm2 -v 2>/dev/null)"
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
    if npm install -g pm2 >/tmp/frosty_pm2_install.log 2>&1; then
        _frosty_ok "pm2 installed: $(pm2 -v 2>/dev/null)"
    else
        _frosty_fail "pm2 install failed — see /tmp/frosty_pm2_install.log"
        return 1
    fi

    return 0
}

# Starts (or restarts if already registered) a process under pm2.
# Usage: _frosty_pm2_start <name> <cwd> <command...>
_frosty_pm2_start() {
    local name="$1"
    local cwd="$2"
    shift 2
    local cmd=("$@")

    if ! command -v pm2 >/dev/null 2>&1; then
        _frosty_fail "pm2 not available — cannot start '$name'"
        return 1
    fi

    if pm2 describe "$name" >/dev/null 2>&1; then
        pm2 restart "$name" >/dev/null 2>&1
    else
        pm2 start "${cmd[0]}" --name "$name" --cwd "$cwd" -- "${cmd[@]:1}" >/dev/null 2>&1
    fi

    sleep 2
    pm2 save >/dev/null 2>&1

    if pm2 describe "$name" 2>/dev/null | grep -q "online"; then
        _frosty_ok "'$name' running under pm2"
        return 0
    else
        _frosty_fail "'$name' failed to reach online state under pm2 — check: pm2 logs $name"
        return 1
    fi
}

_frosty_pm2_status() {
    local name="$1"
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "not running (pm2 not installed)"
        return 1
    fi
    if pm2 describe "$name" 2>/dev/null | grep -q "online"; then
        echo "online"
        return 0
    else
        echo "not running"
        return 1
    fi
}

# Restores all previously-saved pm2 processes (used by Repair).
_frosty_pm2_resurrect() {
    if [[ -d /run/systemd/system ]]; then
        return 0
    fi
    if ! command -v pm2 >/dev/null 2>&1; then
        return 0
    fi
    pm2 resurrect >/dev/null 2>&1
}
