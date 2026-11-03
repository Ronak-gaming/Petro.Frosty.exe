#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPSBOT_DIR="/opt/Frosty-vps-bot"
DEFAULT_WEBSSH_URL="https://freevps.apex1hosting.qzz.io"

vps_bot_installed() {
    [[ -f "${FROSTY_VPSBOT_DIR}/main.py" ]]
}

_frosty_safe_apt_install() {
    mkdir -p /var/cache/apt/tmp /var/cache/apt/archives/partial
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -f -y --no-install-recommends >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    TMPDIR=/var/cache/apt/tmp DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

_frosty_get_private_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || echo "127.0.0.1"
}

_frosty_detect_bot_from_token() {
    local token="$1"
    local resp
    resp="$(curl -s -m 8 -H "Authorization: Bot ${token}" https://discord.com/api/v10/users/@me 2>/dev/null || true)"
    DETECTED_BOT_ID="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))' <<< "$resp" 2>/dev/null)"
    DETECTED_BOT_NAME="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("username",""))' <<< "$resp" 2>/dev/null)"
    [[ -n "$DETECTED_BOT_ID" && -n "$DETECTED_BOT_NAME" ]]
}

_frosty_bot_ensure_ssh_key() {
    mkdir -p "$FROSTY_VPSBOT_DIR"
    if [[ ! -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" ]]; then
        ssh-keygen -t ed25519 -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" -N "" -C "frosty-bot-node" >/dev/null 2>&1
    fi
    chmod 600 "${FROSTY_VPSBOT_DIR}/frosty_node_key" 2>/dev/null || true
}

_frosty_bot_register_node_json() {
    local node_name="$1"
    local is_local="$2"
    local node_ip="$3"
    local ssh_port="${4:-22}"
    local nodes_file="${FROSTY_VPSBOT_DIR}/nodes_data.json"

    python3 - "$nodes_file" "$node_name" "$is_local" "$node_ip" "$ssh_port" << 'PYEOF'
import json, os, sys
path, name, is_local_str, ip, port_str = sys.argv[1:6]
is_local = (is_local_str.lower() == "true")
port = int(port_str) if port_str.isdigit() else 22
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
if is_local:
    for k in list(data.keys()):
        if data[k].get("is_local"):
            del data[k]
data[name] = {"name": name, "is_local": is_local, "ip": ip, "ssh_port": port, "user": "root"}
if not any(v.get("is_local") for v in data.values() if isinstance(v, dict)):
    data["Node-1"] = {"name": "Node-1", "is_local": True, "ip": "127.0.0.1", "ssh_port": 22, "user": "root"}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)
PYEOF
}

install_vps_bot() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Multi-Node VPS Bot (OS Selector + SSHX) ==${C_RESET:-}"

    _frosty_safe_apt_install git nano python3 python3-pip python3-venv sshpass openssh-client openssh-server curl ca-certificates >/tmp/frosty_vpsbot_apt.log 2>&1
    _frosty_ok "Base requirements installed"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        load_module "docker.sh"
        install_docker || true
    fi

    local backup_tmp="/var/cache/apt/tmp/frosty_vpsbot_backup_$$"
    if [[ -d "$FROSTY_VPSBOT_DIR" ]]; then
        mkdir -p "$backup_tmp"
        for data_f in user_data.json vps_data.json admin_data.json invite_data.json nodes_data.json frosty_node_key frosty_node_key.pub; do
            [[ -f "${FROSTY_VPSBOT_DIR}/${data_f}" ]] && cp -a "${FROSTY_VPSBOT_DIR}/${data_f}" "${backup_tmp}/"
        done
        pm2 delete vps-bot >/dev/null 2>&1 || true
        rm -rf "$FROSTY_VPSBOT_DIR"
    fi

    git clone https://github.com/Ronak-gaming/Frosty-vps-bot.git "$FROSTY_VPSBOT_DIR" >/tmp/frosty_vpsbot_clone.log 2>&1
    [[ -d "$backup_tmp" ]] && { cp -a "${backup_tmp}/." "$FROSTY_VPSBOT_DIR/" 2>/dev/null; rm -rf "$backup_tmp"; }

    cd "$FROSTY_VPSBOT_DIR" || return 1
    python3 -m venv venv
    ./venv/bin/pip install -U discord.py flask >/dev/null 2>&1
    _frosty_bot_ensure_ssh_key

    read -rp "  Your Discord user ID (MAIN_ADMIN_ID): " admin_id
    read -rsp "  Bot Token: " bot_token
    echo ""

    local priv_ip
    priv_ip="$(_frosty_get_private_ip)"
    read -rp "  Enter Node IPv4 [${priv_ip}]: " input_node_ip
    local local_node_ip="${input_node_ip:-$priv_ip}"

    if [[ -f config.py ]]; then
        sed -i "s/MAIN_ADMIN_ID[[:space:]]*=.*/MAIN_ADMIN_ID = ${admin_id}/" config.py
        sed -i "s/SERVER_PUBLIC_IP[[:space:]]*=.*/SERVER_PUBLIC_IP = \"${local_node_ip}\//" config.py
    fi

    _frosty_bot_register_node_json "Node-1" "true" "$local_node_ip" "22"

    cat > "${FROSTY_VPSBOT_DIR}/start.sh" << STARTEOF
#!/usr/bin/env bash
cd "${FROSTY_VPSBOT_DIR}"
export DISCORD_BOT_TOKEN="${bot_token}"
export SERVER_PUBLIC_IP="${local_node_ip}"
source venv/bin/activate
exec python3 main.py
STARTEOF
    chmod +x "${FROSTY_VPSBOT_DIR}/start.sh"

    load_module "pm2.sh"
    _frosty_ensure_pm2_always
    _frosty_pm2_start "vps-bot" "$FROSTY_VPSBOT_DIR" "bash" "start.sh"

    _frosty_ok "VPS Bot is online! Command: !create"
}

show_vps_bot_submenu() {
    clear
    print_banner
    echo -e "${C_FROST:-}${C_BOLD:-}╔══════════════════════════════════════════════╗${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}      ${C_ICE:-}${C_BOLD:-}❄  M U L T I - N O D E   B O T  ❄${C_RESET:-}       ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╠══════════════════════════════════════════════╣${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_CYAN:-}[1]${C_RESET:-} ${C_WHITE:-}Install / Reinstall Bot${C_RESET:-}                 ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_PURPLE:-}[2]${C_RESET:-} ${C_WHITE:-}Restart Bot${C_RESET:-}                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_ICE:-}[3]${C_RESET:-} ${C_WHITE:-}View Bot Logs${C_RESET:-}                            ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_BLUE:-}[4]${C_RESET:-} ${C_WHITE:-}Back to Main Menu${C_RESET:-}                        ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╚══════════════════════════════════════════════╝${C_RESET:-}"
    echo ""
    read -rp "  ❄ Select option [1-4]: " choice

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    case "$choice" in
        1) install_vps_bot ;;
        2) [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot && _frosty_ok "Restarted" ;;
        3) [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 30 --nostream ;;
        4) return 0 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_bot_submenu
}

run_vps_bot_flow() {
    show_vps_bot_submenu
}
