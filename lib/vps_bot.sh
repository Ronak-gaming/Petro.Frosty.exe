#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPSBOT_DIR="/opt/Frosty-vps-bot"

vps_bot_installed() {
    [[ -f "${FROSTY_VPSBOT_DIR}/main.py" ]]
}

# Auto-detects ANY Discord Bot's username & ID directly from its Bot Token
_frosty_detect_bot_from_token() {
    local token="$1"
    local resp
    resp="$(curl -s -m 8 -H "Authorization: Bot ${token}" https://discord.com/api/v10/users/@me 2>/dev/null || true)"
    DETECTED_BOT_ID="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("id",""))' <<< "$resp" 2>/dev/null)"
    DETECTED_BOT_NAME="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("username",""))' <<< "$resp" 2>/dev/null)"
    [[ -n "$DETECTED_BOT_ID" && -n "$DETECTED_BOT_NAME" ]]
}

# Ensures the bot's SSH keypair exists for remote node control
_frosty_bot_ensure_ssh_key() {
    mkdir -p "$FROSTY_VPSBOT_DIR"
    if [[ ! -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" ]]; then
        ssh-keygen -t ed25519 -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" -N "" -C "frosty-bot-node" >/dev/null 2>&1
        chmod 600 "${FROSTY_VPSBOT_DIR}/frosty_node_key"
    fi
}

# Safely writes/updates a node entry inside /opt/Frosty-vps-bot/nodes_data.json using python3
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

data[name] = {
    "name": name,
    "is_local": is_local,
    "ip": ip,
    "ssh_port": port,
    "user": "root"
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)
PYEOF
}

# Interactive helper to pair an additional remote VPS node from the terminal
add_vps_bot_remote_node() {
    echo ""
    echo -e "${C_CYAN:-}== Pair Remote VPS Node to Bot ==${C_RESET:-}"

    if ! vps_bot_installed; then
        _frosty_fail "VPS Bot is not installed on this server yet — run [1] Install Bot first"
        return 1
    fi

    _frosty_bot_ensure_ssh_key
    local pubkey
    pubkey="$(cat "${FROSTY_VPSBOT_DIR}/frosty_node_key.pub" 2>/dev/null)"

    read -rp "  Enter a name for the new Node (e.g. Node-2, EU-Node, India-2): " remote_name
    remote_name="$(echo "$remote_name" | tr -cd 'A-Za-z0-9_-')"
    if [[ -z "$remote_name" ]]; then
        _frosty_fail "Node name cannot be empty"
        return 1
    fi

    read -rp "  Enter the Remote VPS Public IPv4: " remote_ip
    remote_ip="${remote_ip//[[:space:]]/}"
    if [[ -z "$remote_ip" ]]; then
        _frosty_fail "Remote IP is required"
        return 1
    fi

    read -rp "  Enter the Remote VPS SSH Port [default: 22]: " remote_port
    remote_port="${remote_port//[[:space:]]/}"
    remote_port="${remote_port:-22}"
    if [[ ! "$remote_port" =~ ^[0-9]+$ ]]; then
        _frosty_fail "SSH port must be a number"
        return 1
    fi

    echo ""
    echo "  How do you want to authenticate with ${remote_name} (${remote_ip}:${remote_port})?"
    echo "    [1] Enter Root Password (auto-copies SSH key & installs Docker automatically)"
    echo "    [2] SSH Key already added manually (skip password)"
    read -rp "  Choice [1-2]: " auth_mode

    if [[ "$auth_mode" != "2" ]]; then
        read -rsp "  Enter Root Password for ${remote_ip}: " remote_pass
        echo ""
        if [[ -z "$remote_pass" ]]; then
            _frosty_fail "Root password cannot be empty"
            return 1
        fi

        if ! command -v sshpass >/dev/null 2>&1; then
            echo "    Installing sshpass..."
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass >/dev/null 2>&1
        fi

        echo "    Connecting to ${remote_name} (${remote_ip}:${remote_port}), installing SSH key & verifying Docker..."
        if ! SSHPASS="$remote_pass" timeout 240 sshpass -e ssh -p "$remote_port" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
            -o LogLevel=ERROR -o ConnectTimeout=12 \
            "root@${remote_ip}" "
                mkdir -p /root/.ssh && chmod 700 /root/.ssh
                grep -qxF '${pubkey}' /root/.ssh/authorized_keys 2>/dev/null || echo '${pubkey}' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
                sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
                systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
                if ! command -v docker >/dev/null 2>&1; then
                    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
                fi
                sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
                if [[ -d /run/systemd/system ]]; then
                    systemctl enable --now docker >/dev/null 2>&1
                else
                    pgrep -x dockerd >/dev/null 2>&1 || (nohup dockerd >/tmp/dockerd.log 2>&1 & sleep 4)
                fi
                docker info >/dev/null 2>&1
            " >/tmp/frosty_node_pair.log 2>&1; then
            _frosty_fail "Failed to pair with ${remote_ip}:${remote_port} — see /tmp/frosty_node_pair.log"
            return 1
        fi
    fi

    echo "    Verifying passwordless SSH key & Docker connection to ${remote_name}..."
    local docker_ver
    if ! docker_ver="$(ssh -i "${FROSTY_VPSBOT_DIR}/frosty_node_key" -p "$remote_port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 \
        "root@${remote_ip}" "docker info --format '{{.ServerVersion}}'" 2>/dev/null)"; then
        _frosty_fail "SSH key verification or Docker check failed on ${remote_ip}:${remote_port}"
        echo -e "    ${C_YELLOW:-}If you chose manual key mode, add this public key to /root/.ssh/authorized_keys on ${remote_ip}:${C_RESET:-}"
        echo "    $pubkey"
        return 1
    fi

    _frosty_bot_register_node_json "$remote_name" "false" "$remote_ip" "$remote_port"
    _frosty_ok "Node '${remote_name}' (${remote_ip}:${remote_port}) paired! Remote Docker v${docker_ver}"

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    if [[ -n "$pm2_bin" ]] && "$pm2_bin" describe vps-bot >/dev/null 2>&1; then
        "$pm2_bin" restart vps-bot >/dev/null 2>&1
        _frosty_ok "VPS Bot restarted — '${remote_name}' is now live in Discord dropdowns!"
    fi
    return 0
}

# Prepares the current machine as a Worker Node for ANY Bot using Bot Token Auto-Detection
prepare_this_server_as_worker_node() {
    echo ""
    echo -e "${C_CYAN:-}== Prepare THIS Server as a Remote Worker Node ==${C_RESET:-}"
    echo "    Works with ANY VPS and ANY Discord Bot (auto-detects your bot via Token)."
    echo ""

    # 1. Ask for Bot Token & auto-detect which Discord Bot they are connecting to
    read -rsp "  Enter the Discord Bot Token this node will belong to: " worker_bot_token
    echo ""
    worker_bot_token="${worker_bot_token//[[:space:]]/}"
    if [[ -z "$worker_bot_token" ]]; then
        _frosty_fail "Bot token is required to identify your bot."
        return 1
    fi

    echo "    Contacting Discord API to identify bot..."
    if ! _frosty_detect_bot_from_token "$worker_bot_token"; then
        _frosty_fail "Invalid Discord Bot Token! Could not detect bot from Discord API."
        return 1
    fi
    _frosty_ok "Auto-Detected Target Bot: ${DETECTED_BOT_NAME} (ID: ${DETECTED_BOT_ID})"

    # 2. Ask what to name this Node
    read -rp "  Enter a name for THIS Worker Node (e.g. Node-2, EU-Node, India-1) [default: Node-2]: " worker_node_name
    worker_node_name="$(echo "${worker_node_name:-Node-2}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$worker_node_name" ]] && worker_node_name="Node-2"

    local my_ip
    my_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo 'YOUR_NODE_IP')}"
    read -rp "  Confirm THIS Server's Public IPv4 [${my_ip}]: " input_my_ip
    my_ip="${input_my_ip:-$my_ip}"

    read -rp "  Enter THIS Server's SSH Port [default: 22]: " my_ssh_port
    my_ssh_port="${my_ssh_port:-22}"

    # 3. Install/Verify Docker
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "    Installing Docker..."
        load_module "docker.sh"
        if ! install_docker; then
            _frosty_fail "Docker installation failed"
            return 1
        fi
    else
        _frosty_ok "Docker is installed and running"
    fi

    # 4. Fix OpenSSH Server & strict /root/.ssh permissions so Permission Denied never happens
    echo "    Ensuring OpenSSH server, Root login, and strict key permissions are enabled..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server curl python3 >/dev/null 2>&1
    mkdir -p /run/sshd /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config 2>/dev/null || true
    if [[ -d /run/systemd/system ]]; then
        systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    else
        pkill -HUP sshd 2>/dev/null || /usr/sbin/sshd
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # 5. Auto-Handshake with Primary Bot OR Paste SSH Key
    echo ""
    read -rp "  Enter Primary Bot VPS IP to Auto-Pair now (or press Enter to paste SSH key manually): " primary_ip
    primary_ip="${primary_ip//[[:space:]]/}"

    if [[ -n "$primary_ip" ]]; then
        [[ "$primary_ip" != *:* ]] && primary_ip="${primary_ip}:8765"
        echo "    Handshaking with ${DETECTED_BOT_NAME} at ${primary_ip}..."
        local pair_resp fetched_key
        pair_resp="$(curl -s -m 10 -X POST "http://${primary_ip}/pair" \
            -d "{\"token\":\"${worker_bot_token}\",\"node_name\":\"${worker_node_name}\",\"ip\":\"${my_ip}\",\"ssh_port\":${my_ssh_port},\"step\":\"init\"}" 2>/dev/null || true)"
        fetched_key="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("pubkey",""))' <<< "$pair_resp" 2>/dev/null)"

        if [[ -n "$fetched_key" ]]; then
            grep -qxF "$fetched_key" /root/.ssh/authorized_keys 2>/dev/null || echo "$fetched_key" >> /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            curl -s -m 10 -X POST "http://${primary_ip}/pair" \
                -d "{\"token\":\"${worker_bot_token}\",\"node_name\":\"${worker_node_name}\",\"ip\":\"${my_ip}\",\"ssh_port\":${my_ssh_port},\"step\":\"confirm\"}" >/dev/null 2>&1 || true
            _frosty_ok "Auto-Paired '${worker_node_name}' (${my_ip}:${my_ssh_port}) with ${DETECTED_BOT_NAME}!"
            echo -e "  ${C_GREEN:-}Done! Type !nodes in Discord to see ${worker_node_name} online.${C_RESET:-}"
            return 0
        else
            _frosty_warn "Could not reach Primary Bot auto-pair port (${primary_ip}) — falling back to SSH key paste."
        fi
    fi

    read -rp "  Paste ${DETECTED_BOT_NAME}'s SSH public key (from !node-key in Discord), or press Enter to skip: " bot_pubkey
    if [[ -n "$bot_pubkey" ]]; then
        grep -qxF "$bot_pubkey" /root/.ssh/authorized_keys 2>/dev/null || echo "$bot_pubkey" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        _frosty_ok "SSH key added for ${DETECTED_BOT_NAME} into /root/.ssh/authorized_keys"
    fi

    _frosty_ok "This server is ready as '${worker_node_name}' for ${DETECTED_BOT_NAME}!"
    echo ""
    echo -e "  ${C_CYAN:-}Next Step — Run this exact command in Discord on ${DETECTED_BOT_NAME}:${C_RESET:-}"
    if [[ -n "$bot_pubkey" ]]; then
        echo -e "    ${C_WHITE}!node-add ${worker_node_name} ${my_ip} ${my_ssh_port} KEY_ONLY${C_RESET}"
    else
        echo -e "    ${C_WHITE}!node-add ${worker_node_name} ${my_ip} ${my_ssh_port} <this_server_root_password>${C_RESET}"
    fi
}
