#!/usr/bin/env bash
# Apex Hosting VPS Bot v4 installer / node manager  (lib/vps_bot.sh)
set -uo pipefail

FROSTY_VPSBOT_DIR="/opt/Frosty-vps-bot"
FROSTY_VPSBOT_REPO="https://github.com/Ronak-gaming/Frosty-vps-bot.git"
FROSTY_WEBSSH_PORT="${PAIR_API_PORT:-8765}"

vps_bot_installed() {
    [[ -f "${FROSTY_VPSBOT_DIR}/main.py" ]]
}

# ── helpers ──────────────────────────────────────────────────────────────
_frosty_safe_apt_install() {
    mkdir -p /var/cache/apt/tmp /var/cache/apt/archives/partial
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -f -y --no-install-recommends >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    if ! TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
        TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
        TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    fi
}

_frosty_get_private_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "127.0.0.1"
}

_frosty_get_public_ip() {
    curl -s -4 -m 5 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

_frosty_is_private_ip() {
    # private, loopback, link-local and CGNAT (100.64.0.0/10, e.g. Tailscale)
    [[ "$1" =~ ^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]
}

declare -F _frosty_menu_row >/dev/null 2>&1 || _frosty_menu_row() {
    local color="$1" label="$2" text="$3" pad
    pad=$(( 45 - ${#label} - ${#text} )); (( pad < 1 )) && pad=1
    printf '%b\n' "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${color}${label}${C_RESET:-} ${C_WHITE:-}${text}${C_RESET:-}$(printf '%*s' "$pad" '')${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
}

# Explains WHY host:port cannot be reached from this machine. Returns 0 if the TCP connection works.
_frosty_tcp_check() {
    local host="$1" port="$2" err rc
    err="$(timeout 6 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && return 0
    if [[ $rc -eq 124 ]]; then
        echo "timed out — a firewall/NAT is dropping packets, or ${host} is a private address on a network this server is not on"
    elif grep -qi "no route" <<< "$err"; then
        echo "No route to host — this server has no path to ${host} (different private network, wrong IP, or a firewall REJECT rule)"
    elif grep -qi "refused" <<< "$err"; then
        echo "connection refused — ${host} is reachable but nothing listens on port ${port} (wrong port or the service is stopped)"
    else
        echo "${err:-connection failed}"
    fi
    return 1
}

_frosty_json_get() {   # $1 = json, $2 = key
    python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); v=d.get(sys.argv[1],""); print("" if v is None else v)' "$2" <<< "$1" 2>/dev/null
}

# Authorise the bot's key for root on THIS worker (key-only; one validated sshd drop-in, nothing else touched).
_frosty_worker_allow_bot_key() {
    local key="$1"
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if [[ -d /etc/ssh/sshd_config.d || -f /etc/ssh/sshd_config ]]; then
        mkdir -p /etc/ssh/sshd_config.d
        printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/00-frosty-bot.conf
        if grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null && /usr/sbin/sshd -t 2>/dev/null; then
            systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        else
            rm -f /etc/ssh/sshd_config.d/00-frosty-bot.conf
            _frosty_warn "sshd has no drop-in support — make sure 'PermitRootLogin prohibit-password' (or yes) is set manually"
        fi
    fi
}

_frosty_detect_bot_from_token() {
    local token="$1" resp
    resp="$(curl -s -m 8 -H "Authorization: Bot ${token}" https://discord.com/api/v10/users/@me 2>/dev/null || true)"
    DETECTED_BOT_ID="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))' <<< "$resp" 2>/dev/null)"
    DETECTED_BOT_NAME="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("username",""))' <<< "$resp" 2>/dev/null)"
    [[ -n "$DETECTED_BOT_ID" && -n "$DETECTED_BOT_NAME" ]]
}

# set KEY=VALUE in the bot's .env (value never passes through sed)
_frosty_env_set() {
    local key="$1" val="$2" f="${FROSTY_VPSBOT_DIR}/.env" tmp
    val="${val//$'\n'/}"
    touch "$f"; chmod 600 "$f"
    tmp="$(mktemp)"
    grep -v "^${key}=" "$f" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

_frosty_env_get() {
    grep -m1 "^$1=" "${FROSTY_VPSBOT_DIR}/.env" 2>/dev/null | cut -d= -f2-
}

# run python inside the bot's venv with its data dir
_frosty_bot_py() {
    ( cd "$FROSTY_VPSBOT_DIR" && DATA_DIR="$FROSTY_VPSBOT_DIR" "${FROSTY_VPSBOT_DIR}/venv/bin/python" "$@" )
}

_frosty_bot_ensure_ssh_key() {
    mkdir -p "$FROSTY_VPSBOT_DIR"
    if [[ ! -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" ]]; then
        ssh-keygen -t ed25519 -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" -N "" -C "frosty-bot-node" >/dev/null 2>&1
    fi
    chmod 600 "${FROSTY_VPSBOT_DIR}/frosty_node_key" 2>/dev/null || true
}

_frosty_bot_restart() {
    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    if [[ -n "$pm2_bin" ]]; then
        "$pm2_bin" restart vps-bot >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ── pair a remote worker (run on the PRIMARY) ────────────────────────────
add_vps_bot_remote_node() {
    echo ""
    echo -e "${C_CYAN:-}== Pair Remote VPS Node From Terminal ==${C_RESET:-}"
    if ! vps_bot_installed; then
        _frosty_fail "VPS Bot is not installed on this server yet — run [1] Install first"
        return 1
    fi
    _frosty_bot_ensure_ssh_key

    read -rp "  Name for the new Node [default: Node-2]: " remote_name
    remote_name="$(echo "${remote_name:-Node-2}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$remote_name" ]] && remote_name="Node-2"
    read -rp "  Node IPv4 (private or public): " remote_ip
    remote_ip="${remote_ip//[[:space:]]/}"
    [[ -z "$remote_ip" ]] && { _frosty_fail "Node IPv4 is required"; return 1; }
    read -rp "  Node SSH port [default: 22]: " remote_port
    remote_port="${remote_port//[[:space:]]/}"; remote_port="${remote_port:-22}"

    echo ""
    echo "  Pairing method for ${remote_name} (${remote_ip}:${remote_port}):"
    echo "    [1] Root password (installs the bot key via sshpass)"
    echo "    [2] Key already authorised (I ran option [3] on the worker)"
    read -rp "  Choice [1-2, default: 1]: " auth_mode
    auth_mode="${auth_mode:-1}"
    local remote_pass=""
    if [[ "${auth_mode}" == "1" ]]; then
        read -rsp "  Root password of ${remote_ip}: " remote_pass; echo ""
        [[ -z "$remote_pass" ]] && { _frosty_fail "Password cannot be empty"; return 1; }
    fi

    echo "    Pairing…"
    local out
    out="$(NODE_NAME="$remote_name" NODE_IP="$remote_ip" NODE_PORT="$remote_port" NODE_PASS="$remote_pass" \
        _frosty_bot_py - << 'PYEOF' 2>&1
import asyncio, os
import docker_utils as du, storage
async def main():
    ok, res = await du.pair_remote_node(os.environ["NODE_NAME"], os.environ["NODE_IP"], int(os.environ["NODE_PORT"]), os.environ.get("NODE_PASS", ""))
    if ok:
        storage.register_node(os.environ["NODE_NAME"], os.environ["NODE_IP"], int(os.environ["NODE_PORT"]))
        print("OK Docker " + res)
    else:
        print("FAIL " + res)
asyncio.run(main())
PYEOF
)"
    if [[ "$out" == OK* ]]; then
        _frosty_ok "Node '${remote_name}' (${remote_ip}:${remote_port}) paired — ${out#OK }"
    else
        _frosty_fail "Pairing failed: ${out#FAIL }"
        echo "    Tip: the worker needs Docker + SSH. Run option [3] on it, or add this key to its /root/.ssh/authorized_keys."
        echo "    Worker on a private network the bot can't reach? Run option [4] -> NAT worker (reverse tunnel) ON the worker."
        echo "    Bot SSH key:"
        cat "${FROSTY_VPSBOT_DIR}/frosty_node_key.pub" 2>/dev/null
        return 1
    fi
    _frosty_bot_restart || true
}

# ── prepare THIS server as a worker (run on the WORKER) ──────────────────
prepare_this_server_as_worker_node() {
    echo ""
    echo -e "${C_CYAN:-}== Setup THIS Server as a Worker Node ==${C_RESET:-}"
    _frosty_safe_apt_install openssh-server curl python3 ca-certificates >/dev/null 2>&1 || true

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        load_module "docker.sh"
        install_docker || return 1
    fi
    _frosty_ok "Docker is installed and running"

    read -rp "  Primary bot URL or IP (e.g. 10.0.0.5 or https://term.example.com): " primary
    primary="${primary//[[:space:]]/}"
    [[ -z "$primary" ]] && { _frosty_fail "Primary address required"; return 1; }
    local base
    if [[ "$primary" =~ ^https?:// ]]; then base="${primary%/}"; else base="http://${primary}:${FROSTY_WEBSSH_PORT}"; fi

    read -rsp "  Pairing secret (shown by /admin webterm in Discord): " pair_secret; echo ""
    pair_secret="${pair_secret//[[:space:]]/}"
    [[ -z "$pair_secret" ]] && { _frosty_fail "Pairing secret required"; return 1; }

    read -rp "  Name for THIS worker [default: Node-2]: " wname
    wname="$(echo "${wname:-Node-2}" | tr -cd 'A-Za-z0-9_-')"; [[ -z "$wname" ]] && wname="Node-2"
    local priv_ip; priv_ip="$(_frosty_get_private_ip)"
    read -rp "  IPv4 the PRIMARY should use to reach this worker [${priv_ip}]: " my_ip
    my_ip="${my_ip:-$priv_ip}"
    read -rp "  This worker's SSH port [default: 22]: " my_port
    my_port="${my_port:-22}"

    local body resp key
    body="$(python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"node_name":sys.argv[2],"ip":sys.argv[3],"ssh_port":int(sys.argv[4]),"step":"init"}))' "$pair_secret" "$wname" "$my_ip" "$my_port")"
    resp="$(curl -s -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "${base}/pair" 2>/dev/null || true)"
    key="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("pubkey",""))' <<< "$resp" 2>/dev/null)"
    if [[ -z "$key" ]]; then
        _frosty_fail "Primary did not answer / wrong secret (${base}/pair). Check the URL, firewall port ${FROSTY_WEBSSH_PORT} and secret."
        return 1
    fi

    _frosty_worker_allow_bot_key "$key"

    body="$(python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"node_name":sys.argv[2],"ip":sys.argv[3],"ssh_port":int(sys.argv[4]),"step":"confirm"}))' "$pair_secret" "$wname" "$my_ip" "$my_port")"
    if curl -s -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "${base}/pair" | grep -q '"ok": true'; then
        _frosty_ok "'${wname}' (${my_ip}:${my_port}) registered on the primary. Verify with /node list in Discord."
    else
        _frosty_warn "Key installed, but registration confirm failed — add it from the primary with /node add"
    fi
}

# ── PRIVATE / NAT worker: reverse tunnel (this server dials OUT to the primary) ──
FROSTY_TUNNEL_WRAPPER="${FROSTY_TUNNEL_WRAPPER:-/usr/local/sbin/frosty-tunnel.sh}"
FROSTY_TUNNEL_KEY="${FROSTY_TUNNEL_KEY:-/root/.ssh/frosty_tunnel_key}"

_frosty_tunnel_install_service() {   # host sshport user tunnelport localssh
    local host="$1" pport="$2" user="$3" tport="$4" lport="$5" ssh_bin
    ssh_bin="$(command -v ssh)"
    cat > "$FROSTY_TUNNEL_WRAPPER" << WRAPEOF
#!/bin/bash
exec ${ssh_bin} -N -i ${FROSTY_TUNNEL_KEY} \\
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \\
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/frosty_tunnel_known_hosts \\
  -o IdentitiesOnly=yes -o BatchMode=yes \\
  -R 127.0.0.1:${tport}:127.0.0.1:${lport} -p ${pport} ${user}@${host}
WRAPEOF
    chmod 755 "$FROSTY_TUNNEL_WRAPPER"

    if [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/frosty-tunnel.service << UNITEOF
[Unit]
Description=Frosty reverse SSH tunnel to the primary bot host
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${FROSTY_TUNNEL_WRAPPER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable frosty-tunnel >/dev/null 2>&1
        systemctl restart frosty-tunnel >/dev/null 2>&1
    else
        _frosty_warn "No systemd — keeping the tunnel alive with pm2"
        load_module "pm2.sh"
        _frosty_ensure_pm2_always >/dev/null 2>&1
        _frosty_pm2_start "frosty-tunnel" "/root" "bash" "$FROSTY_TUNNEL_WRAPPER"
    fi
}

prepare_this_server_as_tunnel_worker() {
    echo ""
    echo -e "${C_CYAN:-}== Setup THIS Server as a PRIVATE / NAT Worker (reverse tunnel) ==${C_RESET:-}"
    echo "  Use this when the bot host CANNOT reach this server (NAT, different private network, 'No route to host')."
    echo "  This server dials OUT to the primary, so no inbound route to it is needed."
    echo "  Needed: the primary's SSH port and bot port (${FROSTY_WEBSSH_PORT}) must be reachable FROM this server."
    echo ""
    _frosty_safe_apt_install openssh-server openssh-client curl python3 ca-certificates >/dev/null 2>&1 || true

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        load_module "docker.sh"
        install_docker || return 1
    fi
    _frosty_ok "Docker is installed and running"

    read -rp "  Primary bot URL or IP (reachable from THIS server): " primary
    primary="${primary//[[:space:]]/}"
    [[ -z "$primary" ]] && { _frosty_fail "Primary address required"; return 1; }
    local base host
    if [[ "$primary" =~ ^https?:// ]]; then base="${primary%/}"; else base="http://${primary}:${FROSTY_WEBSSH_PORT}"; fi
    host="${primary#*://}"; host="${host%%/*}"; host="${host%%:*}"

    local ssh_host ssh_port
    read -rp "  Primary SSH host [${host}]: " ssh_host; ssh_host="${ssh_host:-$host}"
    read -rp "  Primary SSH port [22]: " ssh_port; ssh_port="${ssh_port:-22}"
    local why
    if ! why="$(_frosty_tcp_check "$ssh_host" "$ssh_port")"; then
        _frosty_fail "Cannot reach the primary's SSH at ${ssh_host}:${ssh_port}: ${why}"
        echo "    The tunnel needs THIS server to reach the primary. If neither side can reach the other, use [2] Tailscale first."
        return 1
    fi
    _frosty_ok "Primary SSH ${ssh_host}:${ssh_port} is reachable"

    read -rsp "  Pairing secret (shown by /admin webterm in Discord): " pair_secret; echo ""
    pair_secret="${pair_secret//[[:space:]]/}"
    [[ -z "$pair_secret" ]] && { _frosty_fail "Pairing secret required"; return 1; }
    local wname lport
    read -rp "  Name for THIS worker [default: Node-2]: " wname
    wname="$(echo "${wname:-Node-2}" | tr -cd 'A-Za-z0-9_-')"; [[ -z "$wname" ]] && wname="Node-2"
    read -rp "  THIS server's own SSH port [22]: " lport; lport="${lport:-22}"

    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    [[ -f "$FROSTY_TUNNEL_KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "frosty-tunnel-${wname}" -f "$FROSTY_TUNNEL_KEY"
    local tpub body resp
    tpub="$(cat "${FROSTY_TUNNEL_KEY}.pub")"
    body="$(python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"node_name":sys.argv[2],"tunnel_pubkey":sys.argv[3],"step":"tunnel_init"}))' "$pair_secret" "$wname" "$tpub")"
    resp="$(curl -s -m 15 -X POST -H 'Content-Type: application/json' -d "$body" "${base}/pair" 2>/dev/null || true)"
    if [[ "$(_frosty_json_get "$resp" ok)" != "True" ]]; then
        _frosty_fail "Primary refused / did not answer (${base}/pair): $(_frosty_json_get "$resp" error)"
        echo "    Check the URL, firewall port ${FROSTY_WEBSSH_PORT} and the pairing secret."
        return 1
    fi
    local botkey tport tuser
    botkey="$(_frosty_json_get "$resp" pubkey)"; tport="$(_frosty_json_get "$resp" tunnel_port)"; tuser="$(_frosty_json_get "$resp" tunnel_user)"
    [[ -z "$botkey" || -z "$tport" || -z "$tuser" ]] && { _frosty_fail "Unexpected answer from the primary: ${resp:0:200}"; return 1; }
    _frosty_ok "Primary assigned tunnel port ${tport} (account: ${tuser})"

    _frosty_worker_allow_bot_key "$botkey"
    _frosty_tunnel_install_service "$ssh_host" "$ssh_port" "$tuser" "$tport" "$lport"

    echo "    Waiting for the tunnel to come up..."
    local i cbody cresp
    cbody="$(python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"node_name":sys.argv[2],"step":"tunnel_confirm"}))' "$pair_secret" "$wname")"
    for i in 1 2 3 4 5 6 7 8; do
        sleep 3
        cresp="$(curl -s -m 40 -X POST -H 'Content-Type: application/json' -d "$cbody" "${base}/pair" 2>/dev/null || true)"
        if [[ "$(_frosty_json_get "$cresp" ok)" == "True" ]]; then
            _frosty_ok "'${wname}' is connected through the reverse tunnel (Docker $(_frosty_json_get "$cresp" detail)). Check /node list in Discord."
            echo "    Service: $([[ -d /run/systemd/system ]] && echo 'systemctl status frosty-tunnel' || echo 'pm2 logs frosty-tunnel')"
            return 0
        fi
    done
    _frosty_fail "Tunnel did not come up: $(_frosty_json_get "$cresp" detail)"
    echo "    Debug: $([[ -d /run/systemd/system ]] && echo 'journalctl -u frosty-tunnel -n 30' || echo 'pm2 logs frosty-tunnel')"
    echo "    Common causes: primary sshd has AllowTcpForwarding no, or AllowUsers excludes the tunnel account."
    return 1
}

install_tailscale_helper() {
    echo ""
    echo -e "${C_CYAN:-}== Private network with Tailscale ==${C_RESET:-}"
    echo "  Run this on BOTH the bot host and each worker. They get 100.x addresses that can reach each other"
    echo "  from anywhere; then pair the worker with option [2] using its 100.x address."
    if ! command -v tailscale >/dev/null 2>&1; then
        if ! curl -fsSL --retry 2 -m 60 https://tailscale.com/install.sh -o /tmp/frosty_tailscale_install.sh; then
            _frosty_fail "Could not download the Tailscale installer"; return 1
        fi
        sh /tmp/frosty_tailscale_install.sh >/tmp/frosty_tailscale_install.log 2>&1 || { _frosty_fail "Tailscale install failed — see /tmp/frosty_tailscale_install.log"; return 1; }
    fi
    _frosty_ok "Tailscale installed"
    if [[ ! -d /run/systemd/system ]]; then
        _frosty_warn "No systemd here: Tailscale needs systemd + /dev/net/tun. Use the reverse-tunnel option instead."
        return 1
    fi
    systemctl enable --now tailscaled >/dev/null 2>&1
    echo "  Log in (open the link it prints):"
    tailscale up
    local tip; tip="$(tailscale ip -4 2>/dev/null | head -1)"
    [[ -n "$tip" ]] && _frosty_ok "This server's Tailscale IP: ${tip}  (use it as the node IP; SSH stays hidden from users automatically)"
}

test_node_connectivity() {
    echo ""
    echo -e "${C_CYAN:-}== Test connectivity from THIS server ==${C_RESET:-}"
    local h p why
    read -rp "  Host / IP: " h
    read -rp "  Port [22]: " p; p="${p:-22}"
    [[ -z "$h" ]] && { _frosty_fail "Host required"; return 1; }
    if why="$(_frosty_tcp_check "$h" "$p")"; then
        _frosty_ok "${h}:${p} is reachable from this server"
    else
        _frosty_fail "${h}:${p} — ${why}"
        echo "    Fix: same network/VPN (Tailscale, option [2] here) or the reverse-tunnel worker setup (option [1] here)."
    fi
}

show_vps_bot_private_menu() {
    clear
    print_banner
    echo -e "${C_FROST:-}${C_BOLD:-}╔════════════════════════════════════════════════╗${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}$(_frosty_center "${C_ICE:-}${C_BOLD:-}P R I V A T E  /  N A T  N E T W O R K${C_RESET:-}" 48)${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╠════════════════════════════════════════════════╣${C_RESET:-}"
    _frosty_menu_row "${C_CYAN:-}"   "[1]" "NAT worker (reverse tunnel)"
    _frosty_menu_row "${C_GREEN:-}"  "[2]" "Install Tailscale (private network)"
    _frosty_menu_row "${C_YELLOW:-}" "[3]" "Test connectivity to host:port"
    _frosty_menu_row "${C_BLUE:-}"   "[4]" "Back"
    echo -e "${C_FROST:-}${C_BOLD:-}╚════════════════════════════════════════════════╝${C_RESET:-}"
    echo ""
    read -rp "  Select an option [1-4]: " pn_choice
    case "$pn_choice" in
        1) prepare_this_server_as_tunnel_worker ;;
        2) install_tailscale_helper ;;
        3) test_node_connectivity ;;
        4) return 0 ;;
        *) echo -e "${C_RED:-}Invalid option.${C_RESET:-}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_bot_private_menu
}

# ── node management (primary) ────────────────────────────────────────────
manage_vps_bot_nodes_cli() {
    if ! vps_bot_installed; then _frosty_fail "Install the bot first"; return 1; fi
    echo ""
    echo -e "${C_CYAN:-}== Registered Bot Nodes ==${C_RESET:-}"
    _frosty_bot_py - << 'PYEOF'
import storage
for i, (name, c) in enumerate(storage.get_nodes().items(), 1):
    kind = "Local Primary Host" if c["is_local"] else "Remote Worker Node"
    print(f"  [{i}] {name:18s} | {kind:20s} | IP: {c['ip']}:{c['ssh_port']}")
PYEOF
    echo ""
    echo "  [1] Add / Pair a New Remote Node"
    echo "  [2] Rename a Node"
    echo "  [3] Remove a Remote Node"
    echo "  [4] Change a Node's IP (what users see)"
    echo "  [5] Show Bot SSH Public Key"
    echo "  [6] Back"
    read -rp "  Choice [1-6]: " nm_choice
    case "$nm_choice" in
        1) add_vps_bot_remote_node ;;
        2)
            read -rp "  Current Node name: " old_n
            read -rp "  New Node name: " new_n
            new_n="$(echo "$new_n" | tr -cd 'A-Za-z0-9_-')"
            [[ -z "$old_n" || -z "$new_n" ]] && { _frosty_fail "Both names required"; return 1; }
            local r; r="$(_frosty_bot_py -c 'import sys,storage; print(storage.rename_node(sys.argv[1], sys.argv[2]) or "OK")' "$old_n" "$new_n" 2>&1)"
            [[ "$r" == "OK" ]] && { _frosty_ok "Renamed '$old_n' → '$new_n'"; _frosty_bot_restart; } || _frosty_fail "$r"
            ;;
        3)
            read -rp "  Remote Node name to remove: " del_n
            local r; r="$(_frosty_bot_py -c 'import sys,storage; print(storage.remove_node(sys.argv[1]) or "OK")' "$del_n" 2>&1)"
            [[ "$r" == "OK" ]] && _frosty_ok "Node '$del_n' removed" || _frosty_fail "$r"
            ;;
        4)
            read -rp "  Node name: " n_name
            read -rp "  New IP: " n_ip
            local r; r="$(_frosty_bot_py -c 'import sys,storage; print("OK" if storage.set_node_ip(sys.argv[1], sys.argv[2]) else "Node not found")' "$n_name" "$n_ip" 2>&1)"
            [[ "$r" == "OK" ]] && _frosty_ok "IP updated" || _frosty_fail "$r"
            ;;
        5)
            _frosty_bot_ensure_ssh_key
            cat "${FROSTY_VPSBOT_DIR}/frosty_node_key.pub" 2>/dev/null
            ;;
        *) return 0 ;;
    esac
}

# ── install / update ─────────────────────────────────────────────────────
# Download the bot into a temp dir (git, then git over HTTP/1.1, then a tarball) so a failed
# download can never destroy an existing install.
_frosty_bot_fetch_repo() {
    local dest="$1" log="/tmp/frosty_vpsbot_clone.log"
    local tar_url="https://codeload.github.com/Ronak-gaming/Frosty-vps-bot/tar.gz/refs/heads/main"
    : > "$log"
    export GIT_TERMINAL_PROMPT=0
    rm -rf "$dest"
    echo "    Downloading bot (git)…"
    if timeout 120 git clone --depth 1 "$FROSTY_VPSBOT_REPO" "$dest" >>"$log" 2>&1; then return 0; fi
    echo "--- retry: git over HTTP/1.1" >> "$log"; rm -rf "$dest"
    echo "    git failed, retrying over HTTP/1.1…"
    if timeout 120 git -c http.version=HTTP/1.1 clone --depth 1 "$FROSTY_VPSBOT_REPO" "$dest" >>"$log" 2>&1; then return 0; fi
    echo "--- retry: tarball" >> "$log"; rm -rf "$dest"; mkdir -p "$dest"
    echo "    git failed, trying direct download…"
    if curl -fsSL --retry 3 --connect-timeout 15 -m 180 "$tar_url" 2>>"$log" | tar -xz -C "$dest" --strip-components=1 2>>"$log" \
       && [[ -f "${dest}/main.py" ]]; then return 0; fi
    rm -rf "$dest"
    return 1
}

_frosty_bot_backup_and_clone() {
    local new_dir="${FROSTY_VPSBOT_DIR}.new"

    if ! _frosty_bot_fetch_repo "$new_dir"; then
        _frosty_fail "Could not download the bot from ${FROSTY_VPSBOT_REPO}"
        echo "    Last lines of /tmp/frosty_vpsbot_clone.log:"
        tail -n 8 /tmp/frosty_vpsbot_clone.log 2>/dev/null | sed 's/^/      /'
        echo "    Check: internet/DNS to github.com, that the repo is public, and that 'curl -I https://github.com' works here."
        [[ -d "$FROSTY_VPSBOT_DIR" ]] && echo "    Your existing install was NOT touched."
        return 1
    fi

    # The repo must contain the v4 bot, otherwise the old (broken) one would be installed.
    local need
    for need in main.py webterm.py storage.py docker_utils.py views.py config.py requirements.txt terminal.html static/xterm.js; do
        if [[ ! -e "${new_dir}/${need}" ]]; then
            _frosty_fail "The repository does not contain the v4 bot (missing: ${need})."
            echo "    Upload the contents of Apex-Hosting-vps-bot-v4.zip (files at the repo root) to ${FROSTY_VPSBOT_REPO} (branch main), then retry."
            rm -rf "$new_dir"
            return 1
        fi
    done

    if [[ -d "$FROSTY_VPSBOT_DIR" ]]; then
        local f
        for f in .env frosty.db frosty.db-wal frosty.db-shm user_data.json vps_data.json admin_data.json \
                 invite_data.json nodes_data.json frosty_node_key frosty_node_key.pub known_hosts; do
            [[ -f "${FROSTY_VPSBOT_DIR}/${f}" ]] && cp -a "${FROSTY_VPSBOT_DIR}/${f}" "${new_dir}/" 2>/dev/null
        done
        load_module "pm2.sh"
        local pm2_bin; pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" delete vps-bot >/dev/null 2>&1
        rm -rf "${FROSTY_VPSBOT_DIR}.bak"
        mv "$FROSTY_VPSBOT_DIR" "${FROSTY_VPSBOT_DIR}.bak"
        _frosty_ok "Kept your database, credits, nodes, keys and settings (old copy: ${FROSTY_VPSBOT_DIR}.bak)"
    fi
    mv "$new_dir" "$FROSTY_VPSBOT_DIR"
    return 0
}

_frosty_bot_python_deps() {
    cd "$FROSTY_VPSBOT_DIR" || return 1
    [[ -d venv ]] || python3 -m venv venv >/tmp/frosty_vpsbot_venv.log 2>&1
    if ! ./venv/bin/pip install -q -U pip >>/tmp/frosty_vpsbot_venv.log 2>&1 \
       || ! ./venv/bin/pip install -q -U -r requirements.txt >>/tmp/frosty_vpsbot_venv.log 2>&1; then
        _frosty_fail "Python dependency install failed — see /tmp/frosty_vpsbot_venv.log"
        return 1
    fi
    _frosty_ok "Python dependencies installed"
}

_frosty_bot_write_start_and_run() {
    cat > "${FROSTY_VPSBOT_DIR}/start.sh" << STARTEOF
#!/usr/bin/env bash
cd "${FROSTY_VPSBOT_DIR}"
exec "${FROSTY_VPSBOT_DIR}/venv/bin/python" main.py
STARTEOF
    chmod 700 "${FROSTY_VPSBOT_DIR}/start.sh"
    load_module "pm2.sh"
    _frosty_ensure_pm2_always
    _frosty_pm2_start "vps-bot" "$FROSTY_VPSBOT_DIR" "bash" "start.sh"
}

install_vps_bot() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Apex Hosting VPS Bot v4 (slash commands + Web Terminal) ==${C_RESET:-}"

    if ! _frosty_safe_apt_install git nano python3 python3-pip python3-venv sshpass openssh-client openssh-server curl ca-certificates >/tmp/frosty_vpsbot_apt.log 2>&1; then
        _frosty_fail "Base package install failed — see /tmp/frosty_vpsbot_apt.log"
        return 1
    fi
    _frosty_ok "Base requirements installed"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        load_module "docker.sh"
        install_docker || true
    fi
    if ! docker info >/dev/null 2>&1; then
        _frosty_warn "Docker is NOT usable on this server (restricted container / no systemd?)."
        echo "    The bot will install, but THIS node cannot run VPS containers."
        echo "    Deploy on a real VPS/VM, or add worker nodes that have working Docker (option [2] / [3])."
    fi

    _frosty_bot_backup_and_clone "/var/cache/apt/tmp/frosty_vpsbot_backup_$$" || return 1
    _frosty_bot_python_deps || return 1
    _frosty_bot_ensure_ssh_key

    echo ""
    local admin_id bot_token cur_admin cur_token
    cur_admin="$(_frosty_env_get MAIN_ADMIN_ID)"; cur_token="$(_frosty_env_get DISCORD_BOT_TOKEN)"
    read -rp "  Your Discord user ID (MAIN_ADMIN_ID)${cur_admin:+ [${cur_admin}]}: " admin_id
    admin_id="${admin_id//[[:space:]]/}"; admin_id="${admin_id:-$cur_admin}"
    if [[ ! "$admin_id" =~ ^[0-9]{15,22}$ ]]; then
        _frosty_fail "That doesn't look like a Discord user ID (enable Developer Mode → right-click yourself → Copy User ID)"
        return 1
    fi
    read -rsp "  Bot token${cur_token:+ [Enter = keep existing]}: " bot_token; echo ""
    bot_token="${bot_token//[[:space:]]/}"; bot_token="${bot_token:-$cur_token}"
    [[ -z "$bot_token" ]] && { _frosty_fail "Bot token required"; return 1; }
    if _frosty_detect_bot_from_token "$bot_token"; then
        _frosty_ok "Auto-Detected Discord Bot: ${DETECTED_BOT_NAME} (ID: ${DETECTED_BOT_ID})"
        echo "    Invite link (scopes bot + applications.commands):"
        echo "    https://discord.com/oauth2/authorize?client_id=${DETECTED_BOT_ID}&scope=bot%20applications.commands&permissions=2147483648"
    else
        _frosty_warn "Could not verify the token with Discord (offline or wrong token) — continuing"
    fi

    local cur_name; cur_name="$(_frosty_env_get LOCAL_NODE_NAME)"
    read -rp "  Name for THIS Primary Node [default: ${cur_name:-Node-1}]: " primary_node_name
    primary_node_name="$(echo "${primary_node_name:-${cur_name:-Node-1}}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$primary_node_name" ]] && primary_node_name="Node-1"

    local pub_ip priv_ip default_ip node_ip
    pub_ip="$(_frosty_get_public_ip)"; priv_ip="$(_frosty_get_private_ip)"
    default_ip="${pub_ip:-$priv_ip}"
    read -rp "  IPv4 of THIS node (shown to users) [${default_ip}]: " node_ip
    node_ip="${node_ip:-$default_ip}"
    node_ip="${node_ip//[[:space:]]/}"

    # Web console URL: private IP / NAT needs a reachable base URL
    local web_url="" ssh_mode="auto"
    if _frosty_is_private_ip "$node_ip"; then
        echo ""
        echo -e "  ${C_YELLOW:-}Private IP detected (${node_ip}).${C_RESET:-} Raw SSH (ssh root@ip -p port) will be HIDDEN from users;"
        echo "  they connect through the Web Console and SSHX only. (Change later with SSH_DISPLAY=always in .env.)"
    fi
    if _frosty_is_private_ip "$node_ip" || [[ -z "$pub_ip" ]]; then
        echo ""
        echo -e "  ${C_YELLOW:-}Private/NAT address detected.${C_RESET:-} Web console links will only open from your LAN/VPN."
        echo "  For access from anywhere, put a Cloudflare Tunnel (service http://localhost:${FROSTY_WEBSSH_PORT}) in front and enter its URL."
        read -rp "  Public console URL (e.g. https://term.example.com) [Enter = use http://${node_ip}:${FROSTY_WEBSSH_PORT}]: " web_url
        web_url="${web_url%/}"
    fi

    _frosty_env_set DISCORD_BOT_TOKEN "$bot_token"
    _frosty_env_set MAIN_ADMIN_ID "$admin_id"
    _frosty_env_set LOCAL_NODE_NAME "$primary_node_name"
    _frosty_env_set SERVER_PUBLIC_IP "$node_ip"
    _frosty_env_get SSH_DISPLAY >/dev/null 2>&1 && [[ -n "$(_frosty_env_get SSH_DISPLAY)" ]] || _frosty_env_set SSH_DISPLAY "$ssh_mode"
    _frosty_env_set WEB_PORT "$FROSTY_WEBSSH_PORT"
    [[ -n "$web_url" ]] && _frosty_env_set WEB_BASE_URL "$web_url"
    chmod 600 "${FROSTY_VPSBOT_DIR}/.env"
    _frosty_ok "Settings saved to ${FROSTY_VPSBOT_DIR}/.env"

    # (re)name the local node record in the DB so old VPS records follow it
    _frosty_bot_py - "$primary_node_name" "$node_ip" << 'PYEOF' >/dev/null 2>&1 || true
import sys, time, storage
name, ip = sys.argv[1], sys.argv[2]
c = storage.db()
loc = [r["name"] for r in c.execute("SELECT name FROM nodes WHERE is_local=1")]
for old in loc:
    if old != name:
        c.execute("UPDATE vps SET node=? WHERE node=?", (name, old))
        c.execute("DELETE FROM nodes WHERE name=?", (old,))
c.execute("INSERT OR REPLACE INTO nodes(name,ip,ssh_port,user,is_local,added_at) VALUES(?,?,22,'root',1,?)", (name, ip, time.time()))
PYEOF

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${FROSTY_WEBSSH_PORT}/tcp" >/dev/null 2>&1 && _frosty_ok "ufw: opened ${FROSTY_WEBSSH_PORT}/tcp (web console + pairing)"
    fi

    _frosty_bot_write_start_and_run
    sleep 3
    if curl -fs -m 5 "http://127.0.0.1:${FROSTY_WEBSSH_PORT}/health" >/dev/null 2>&1; then
        _frosty_ok "Web terminal server is up on port ${FROSTY_WEBSSH_PORT}"
    else
        _frosty_warn "Web terminal not answering yet — check logs with option [8]"
    fi
    echo "    Console links will use: $(_frosty_bot_py -c 'import config; print(config.web_base_url())' 2>/dev/null)"
    echo "    SSH display for node IP ${node_ip}: $(_frosty_bot_py -c 'import config,sys; print("shown" if config.ssh_exposed(sys.argv[1]) else "hidden (private IP -> Web Console / SSHX only)")' "$node_ip" 2>/dev/null)"
    _frosty_ok "VPS Bot is online with node '${primary_node_name}'! Use /help in Discord (slash commands)."
    echo "    Wrong console link? In Discord run: /admin seturl https://your-tunnel-domain"
    echo "    Pairing secret for workers: run /admin webterm in Discord, or option [7] here."
}

update_vps_bot() {
    echo ""
    echo -e "${C_CYAN:-}== Updating VPS Bot (data is kept) ==${C_RESET:-}"
    vps_bot_installed || { _frosty_fail "Bot not installed"; return 1; }
    _frosty_bot_backup_and_clone "/var/cache/apt/tmp/frosty_vpsbot_backup_$$" || return 1
    _frosty_bot_python_deps || return 1
    _frosty_bot_write_start_and_run
    _frosty_ok "Bot updated and restarted"
}

show_vps_bot_pair_secret() {
    vps_bot_installed || { _frosty_fail "Bot not installed"; return 1; }
    echo ""
    echo -e "${C_CYAN:-}== Worker Pairing Info ==${C_RESET:-}"
    echo "  Pairing URL : http://<this-server-ip>:${FROSTY_WEBSSH_PORT}  (or your WEB_BASE_URL)"
    echo -n "  Secret      : "
    _frosty_bot_py -c 'import storage; print(storage.get_pair_secret())' 2>/dev/null
    echo "  Console URL : $(_frosty_env_get WEB_BASE_URL)"
}

show_vps_bot_submenu() {
    clear
    print_banner
    echo -e "${C_FROST:-}${C_BOLD:-}╔════════════════════════════════════════════════╗${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}$(_frosty_center "${C_ICE:-}${C_BOLD:-}❄  M U L T I - N O D E   B O T  ❄${C_RESET:-}" 48)${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╠════════════════════════════════════════════════╣${C_RESET:-}"
    _frosty_menu_row "${C_CYAN:-}"   "[1]" "Install / Reinstall Bot"
    _frosty_menu_row "${C_GREEN:-}"  "[2]" "Add / Pair Remote VPS Node (Terminal)"
    _frosty_menu_row "${C_YELLOW:-}" "[3]" "Setup THIS Server as Worker Node"
    _frosty_menu_row "${C_PURPLE:-}" "[4]" "Private / NAT Network Tools >"
    _frosty_menu_row "${C_ICE:-}"    "[5]" "Manage / Rename Nodes"
    _frosty_menu_row "${C_PURPLE:-}" "[6]" "Restart Bot"
    _frosty_menu_row "${C_CYAN:-}"   "[7]" "Show Worker Pairing Secret"
    _frosty_menu_row "${C_ICE:-}"    "[8]" "View Bot Logs"
    _frosty_menu_row "${C_GREEN:-}"  "[9]" "Update Bot (keep data)"
    _frosty_menu_row "${C_BLUE:-}"   "[0]" "Back to Main Menu"
    echo -e "${C_FROST:-}${C_BOLD:-}╚════════════════════════════════════════════════╝${C_RESET:-}"
    echo ""
    read -rp "  ❄ Select an option [0-9]: " bot_choice

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    case "$bot_choice" in
        1) install_vps_bot ;;
        2) add_vps_bot_remote_node ;;
        3) prepare_this_server_as_worker_node ;;
        4) show_vps_bot_private_menu ;;
        5) manage_vps_bot_nodes_cli ;;
        6) if [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot >/dev/null 2>&1; then _frosty_ok "Restarted"; else _frosty_fail "Bot is not running under pm2 — use [1] or [9]"; fi ;;
        7) show_vps_bot_pair_secret ;;
        8) [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 40 --nostream ;;
        9) update_vps_bot ;;
        0) return 0 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_bot_submenu
}

run_vps_bot_flow() {
    show_vps_bot_submenu
}
