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

# Unlocks OpenSSH on the current machine so "Permission denied" NEVER happens
_frosty_unlock_local_ssh() {
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sshpass curl python3 >/dev/null 2>&1
    chown root:root /root 2>/dev/null || true
    chmod 700 /root 2>/dev/null || true
    mkdir -p /run/sshd /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh 2>/dev/null || true

    # Remove cloud-init / Ubuntu drop-in overrides that block root/pubkey/password login
    rm -f /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true

    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*StrictModes.*/StrictModes no/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config 2>/dev/null || true

    grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
    grep -q "^StrictModes no" /etc/ssh/sshd_config || echo "StrictModes no" >> /etc/ssh/sshd_config

    if [[ -d /run/systemd/system ]]; then
        systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    else
        pkill -HUP sshd 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
    fi
}

# Ensures the bot's SSH keypair exists for remote node control
_frosty_bot_ensure_ssh_key() {
    mkdir -p "$FROSTY_VPSBOT_DIR"
    if [[ ! -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" ]]; then
        ssh-keygen -t ed25519 -f "${FROSTY_VPSBOT_DIR}/frosty_node_key" -N "" -C "frosty-bot-node" >/dev/null 2>&1
    fi
    chmod 600 "${FROSTY_VPSBOT_DIR}/frosty_node_key" 2>/dev/null || true
}

# Safely writes/updates a node entry inside /opt/Frosty-vps-bot/nodes_data.json using python3 (Always keeps Node-1)
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

# Ensure Node-1 local host exists if no local node is present
if not any(v.get("is_local") for v in data.values() if isinstance(v, dict)):
    data["Node-1"] = {
        "name": "Node-1",
        "is_local": True,
        "ip": "127.0.0.1",
        "ssh_port": 22,
        "user": "root"
    }

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4)
PYEOF
}

# Option [2]: Pair an additional remote VPS node directly from the Primary VPS terminal (No Discord needed)
add_vps_bot_remote_node() {
    echo ""
    echo -e "${C_CYAN:-}== Pair Remote VPS Node Directly From Terminal (No Discord Needed) ==${C_RESET:-}"

    if ! vps_bot_installed; then
        _frosty_fail "VPS Bot is not installed on this server yet — run [1] Install Bot first"
        return 1
    fi

    _frosty_bot_ensure_ssh_key
    local pubkey
    pubkey="$(cat "${FROSTY_VPSBOT_DIR}/frosty_node_key.pub" 2>/dev/null)"

    read -rp "  Enter a name for the new Node [default: Node-2]: " remote_name
    remote_name="$(echo "${remote_name:-Node-2}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$remote_name" ]] && remote_name="Node-2"

    read -rp "  Enter the Remote VPS Public IPv4 (e.g. 116.66.214.191): " remote_ip
    remote_ip="${remote_ip//[[:space:]]/}"
    if [[ -z "$remote_ip" ]]; then
        _frosty_fail "Remote IP is required"
        return 1
    fi

    read -rp "  Enter the Remote VPS SSH Port [default: 22]: " remote_port
    remote_port="${remote_port//[[:space:]]/}"
    remote_port="${remote_port:-22}"

    echo ""
    echo "  How do you want to pair ${remote_name} (${remote_ip}:${remote_port})?"
    echo "    [1] Enter Root Password of ${remote_ip} (Auto-unlocks SSH, copies key & registers node)"
    echo "    [2] I already ran Option [3] on ${remote_ip} (Pair without password)"
    read -rp "  Choice [1-2, default: 1]: " auth_mode
    auth_mode="${auth_mode:-1}"

    if [[ "$auth_mode" == "1" ]]; then
        read -rsp "  Enter Root Password for ${remote_ip}: " remote_pass
        echo ""
        if [[ -z "$remote_pass" ]]; then
            _frosty_fail "Root password cannot be empty"
            return 1
        fi

        if ! command -v sshpass >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass >/dev/null 2>&1
        fi

        echo "    Connecting to ${remote_name} (${remote_ip}:${remote_port}), unlocking SSH & installing key..."
        if ! SSHPASS="$remote_pass" timeout 240 sshpass -e ssh -p "$remote_port" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
            -o LogLevel=ERROR -o ConnectTimeout=15 \
            "root@${remote_ip}" "
                chown root:root /root && chmod 700 /root
                mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
                touch /root/.ssh/authorized_keys
                grep -qxF '${pubkey}' /root/.ssh/authorized_keys 2>/dev/null || echo '${pubkey}' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                chown -R root:root /root/.ssh
                rm -f /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
                sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
                sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
                sed -i 's/^#*StrictModes.*/StrictModes no/' /etc/ssh/sshd_config 2>/dev/null || true
                sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config 2>/dev/null || true
                systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || pkill -HUP sshd 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
                if ! command -v docker >/dev/null 2>&1; then
                    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
                fi
                if [[ -d /run/systemd/system ]]; then
                    systemctl enable --now docker >/dev/null 2>&1
                else
                    pgrep -x dockerd >/dev/null 2>&1 || (nohup dockerd >/tmp/dockerd.log 2>&1 & sleep 4)
                fi
            " >/tmp/frosty_node_pair.log 2>&1; then
            _frosty_fail "Password login to ${remote_ip}:${remote_port} failed — check password or run Option [3] on ${remote_ip} directly."
            return 1
        fi
    fi

    echo "    Verifying passwordless SSH key connection to ${remote_name}..."
    local docker_ver
    if ! docker_ver="$(ssh -i "${FROSTY_VPSBOT_DIR}/frosty_node_key" -p "$remote_port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 \
        "root@${remote_ip}" "docker info --format '{{.ServerVersion}}'" 2>/dev/null)"; then
        _frosty_fail "SSH key check failed on ${remote_ip}:${remote_port}"
        return 1
    fi

    _frosty_bot_register_node_json "$remote_name" "false" "$remote_ip" "$remote_port"
    _frosty_ok "Node '${remote_name}' (${remote_ip}:${remote_port}) added to nodes_data.json! (Docker v${docker_ver})"

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    if [[ -n "$pm2_bin" ]] && "$pm2_bin" describe vps-bot >/dev/null 2>&1; then
        "$pm2_bin" restart vps-bot >/dev/null 2>&1
        _frosty_ok "VPS Bot restarted — '${remote_name}' is live right now without needing any Discord command!"
    fi
    return 0
}

# Option [3]: Run on Node-2 / Worker VPS — pairs itself directly into the Primary VPS without touching Discord!
prepare_this_server_as_worker_node() {
    echo ""
    echo -e "${C_CYAN:-}== Setup THIS Server as a Worker Node (Direct VPS-to-VPS Auto-Add) ==${C_RESET:-}"
    echo "    Adds this VPS directly to your Bot's nodes list without needing Discord commands!"
    echo ""

    # 1. Unlock SSH permissions & StrictModes on THIS worker node immediately
    echo "    [1/4] Unlocking OpenSSH & fixing /root/.ssh permissions on THIS server..."
    _frosty_unlock_local_ssh
    _frosty_ok "OpenSSH Root & Pubkey permissions unlocked on this server"

    # 2. Ensure Docker is running on THIS worker node
    echo "    [2/4] Checking Docker..."
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        load_module "docker.sh"
        if ! install_docker; then
            _frosty_fail "Docker installation failed"
            return 1
        fi
    fi
    _frosty_ok "Docker is installed and running"

    # 3. Ask for Bot Token & auto-detect which Bot this node is being added to
    read -rsp "  Enter your Discord Bot Token (to auto-detect your bot): " worker_bot_token
    echo ""
    worker_bot_token="${worker_bot_token//[[:space:]]/}"
    if [[ -n "$worker_bot_token" ]] && _frosty_detect_bot_from_token "$worker_bot_token"; then
        _frosty_ok "Auto-Detected Target Bot: ${DETECTED_BOT_NAME} (ID: ${DETECTED_BOT_ID})"
    else
        DETECTED_BOT_NAME="Your VPS Bot"
        _frosty_warn "Continuing with direct VPS pairing..."
    fi

    # 4. Ask for Node Name & IP details
    read -rp "  Enter a name for THIS Worker Node [default: Node-2]: " worker_node_name
    worker_node_name="$(echo "${worker_node_name:-Node-2}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$worker_node_name" ]] && worker_node_name="Node-2"

    local my_ip
    my_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo '116.66.214.191')}"
    read -rp "  Confirm THIS Worker VPS Public IPv4 [${my_ip}]: " input_my_ip
    my_ip="${input_my_ip:-$my_ip}"

    read -rp "  Enter THIS Worker VPS SSH Port [default: 22]: " my_ssh_port
    my_ssh_port="${my_ssh_port:-22}"

    echo ""
    echo -e "${C_CYAN:-}== Direct VPS-to-VPS Pairing (No Discord Required) ==${C_RESET:-}"
    read -rp "  Enter the Primary Bot VPS IP (where Node-1 / the bot is hosted): " primary_ip
    primary_ip="${primary_ip//[[:space:]]/}"

    if [[ -z "$primary_ip" ]]; then
        _frosty_fail "Primary Bot VPS IP is required to auto-register ${worker_node_name}."
        return 1
    fi

    # Try Method A: Instant API Handshake over port 8765 using Bot Token
    if [[ -n "$worker_bot_token" ]]; then
        echo "    Attempting instant token handshake with Primary Bot (${primary_ip}:8765)..."
        local pair_resp fetched_key
        pair_resp="$(curl -s -m 8 -X POST "http://${primary_ip}:8765/pair" \
            -d "{\"token\":\"${worker_bot_token}\",\"node_name\":\"${worker_node_name}\",\"ip\":\"${my_ip}\",\"ssh_port\":${my_ssh_port},\"step\":\"init\"}" 2>/dev/null || true)"
        fetched_key="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get("pubkey",""))' <<< "$pair_resp" 2>/dev/null)"

        if [[ -n "$fetched_key" ]]; then
            grep -qxF "$fetched_key" /root/.ssh/authorized_keys 2>/dev/null || echo "$fetched_key" >> /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            chown -R root:root /root/.ssh
            _frosty_unlock_local_ssh
            curl -s -m 8 -X POST "http://${primary_ip}:8765/pair" \
                -d "{\"token\":\"${worker_bot_token}\",\"node_name\":\"${worker_node_name}\",\"ip\":\"${my_ip}\",\"ssh_port\":${my_ssh_port},\"step\":\"confirm\"}" >/dev/null 2>&1 || true
            _frosty_ok "SUCCESS! '${worker_node_name}' (${my_ip}:${my_ssh_port}) is now registered on ${DETECTED_BOT_NAME}!"
            echo -e "  ${C_GREEN:-}No Discord command needed! Node-1 and ${worker_node_name} are both live!${C_RESET:-}"
            return 0
        fi
    fi

    # Method B: Guaranteed Direct SSH Handshake to Primary VPS (works even if port 8765 isn't open)
    echo "    Connecting directly to Primary Bot VPS (${primary_ip}) via SSH to register ${worker_node_name}..."
    read -rp "  Enter Primary Bot VPS SSH Port [default: 22]: " primary_port
    primary_port="${primary_port:-22}"
    read -rsp "  Enter Primary Bot VPS (${primary_ip}) Root Password: " primary_pass
    echo ""

    if [[ -z "$primary_pass" ]]; then
        _frosty_fail "Primary VPS root password is required for direct SSH registration."
        return 1
    fi

    # 1. Fetch Primary Bot's SSH public key
    local primary_pubkey
    primary_pubkey="$(SSHPASS="$primary_pass" sshpass -e ssh -p "$primary_port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
        -o LogLevel=ERROR -o ConnectTimeout=15 \
        "root@${primary_ip}" "
            mkdir -p /opt/Frosty-vps-bot
            if [[ ! -f /opt/Frosty-vps-bot/frosty_node_key ]]; then
                ssh-keygen -t ed25519 -f /opt/Frosty-vps-bot/frosty_node_key -N '' -C 'frosty-bot-node' >/dev/null 2>&1
                chmod 600 /opt/Frosty-vps-bot/frosty_node_key
            fi
            cat /opt/Frosty-vps-bot/frosty_node_key.pub
        " 2>/dev/null)"

    if [[ -z "$primary_pubkey" ]]; then
        _frosty_fail "Could not log into Primary VPS (${primary_ip}:${primary_port}) — check password."
        return 1
    fi

    # 2. Authorize Primary Bot's SSH key on THIS worker node
    grep -qxF "$primary_pubkey" /root/.ssh/authorized_keys 2>/dev/null || echo "$primary_pubkey" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh
    _frosty_unlock_local_ssh
    _frosty_ok "Authorized Primary Bot SSH key on ${worker_node_name}"

    # 3. Tell Primary VPS to test the SSH connection, register Node-1 + Node-2 into nodes_data.json, and restart the bot
    if SSHPASS="$primary_pass" sshpass -e ssh -p "$primary_port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
        -o LogLevel=ERROR -o ConnectTimeout=15 \
        "root@${primary_ip}" "
            python3 - '/opt/Frosty-vps-bot/nodes_data.json' '${worker_node_name}' '${my_ip}' '${my_ssh_port}' '${primary_ip}' << 'PYEOF'
import json, os, sys
path, name, ip, port_str, prim_ip = sys.argv[1:6]
data = {}
if os.path.exists(path):
    try:
        with open(path, 'r') as f: data = json.load(f)
    except Exception: data = {}
if not any(v.get('is_local') for v in data.values() if isinstance(v, dict)):
    data['Node-1'] = {'name': 'Node-1', 'is_local': True, 'ip': prim_ip, 'ssh_port': 22, 'user': 'root'}
data[name] = {'name': name, 'is_local': False, 'ip': ip, 'ssh_port': int(port_str), 'user': 'root'}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f: json.dump(data, f, indent=4)
PYEOF
            pm2 restart vps-bot >/dev/null 2>&1 || /root/.nvm/versions/node/*/bin/pm2 restart vps-bot >/dev/null 2>&1 || true
        " >/dev/null 2>&1; then
        _frosty_ok "SUCCESS! '${worker_node_name}' (${my_ip}:${my_ssh_port}) and 'Node-1' are now registered on ${DETECTED_BOT_NAME}!"
        echo -e "  ${C_GREEN:-}All done from the VPS terminal! You do NOT need to run !node-add in Discord.${C_RESET:-}"
    else
        _frosty_fail "Failed to write nodes_data.json on Primary VPS."
        return 1
    fi
}

manage_vps_bot_nodes_cli() {
    echo ""
    echo -e "${C_CYAN:-}== Registered Bot Nodes ==${C_RESET:-}"
    local nodes_file="${FROSTY_VPSBOT_DIR}/nodes_data.json"
    if [[ ! -f "$nodes_file" ]]; then
        local local_ip
        local_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo '127.0.0.1')}"
        _frosty_bot_register_node_json "Node-1" "true" "$local_ip" "22"
    fi

    python3 - "$nodes_file" << 'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
if not data:
    print("  No nodes registered.")
for i, (name, cfg) in enumerate(data.items(), 1):
    kind = "Local Primary Host" if cfg.get("is_local") else "Remote Worker Node"
    print(f"  [{i}] {name:18s} | {kind:20s} | IP: {cfg.get('ip', '?')}:{cfg.get('ssh_port', 22)}")
PYEOF

    echo ""
    echo "  [1] Add / Pair a New Remote Node (From Terminal)"
    echo "  [2] Rename a Node"
    echo "  [3] Remove a Remote Node"
    echo "  [4] Show Bot SSH Public Key"
    echo "  [5] Back"
    read -rp "  Choice [1-5]: " nm_choice

    case "$nm_choice" in
        1) add_vps_bot_remote_node ;;
        2)
            read -rp "  Current Node name: " old_n
            read -rp "  New Node name: " new_n
            new_n="$(echo "$new_n" | tr -cd 'A-Za-z0-9_-')"
            if [[ -z "$old_n" || -z "$new_n" ]]; then
                _frosty_fail "Both old and new names are required"
                return 1
            fi
            python3 - "$nodes_file" "${FROSTY_VPSBOT_DIR}/vps_data.json" "$old_n" "$new_n" << 'PYEOF'
import json, os, sys
n_path, v_path, old_n, new_n = sys.argv[1:5]
with open(n_path, "r", encoding="utf-8") as f:
    nodes = json.load(f)
if old_n not in nodes:
    sys.exit(1)
cfg = nodes.pop(old_n)
cfg["name"] = new_n
nodes[new_n] = cfg
with open(n_path, "w", encoding="utf-8") as f:
    json.dump(nodes, f, indent=4)
if os.path.exists(v_path):
    with open(v_path, "r", encoding="utf-8") as f:
        vps = json.load(f)
    for vl in vps.values():
        if isinstance(vl, list):
            for v in vl:
                if v.get("node") == old_n:
                    v["node"] = new_n
    with open(v_path, "w", encoding="utf-8") as f:
        json.dump(vps, f, indent=4)
PYEOF
            if [[ $? -eq 0 ]]; then
                _frosty_ok "Node '$old_n' renamed to '$new_n'"
                load_module "pm2.sh"
                local pm2_bin
                pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
                [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot >/dev/null 2>&1
            else
                _frosty_fail "Node '$old_n' not found"
            fi
            ;;
        3)
            read -rp "  Remote Node name to remove: " del_n
            python3 - "$nodes_file" "$del_n" << 'PYEOF'
import json, sys
n_path, del_n = sys.argv[1:3]
with open(n_path, "r", encoding="utf-8") as f:
    nodes = json.load(f)
if del_n not in nodes:
    sys.exit(1)
if nodes[del_n].get("is_local"):
    sys.exit(2)
del nodes[del_n]
with open(n_path, "w", encoding="utf-8") as f:
    json.dump(nodes, f, indent=4)
PYEOF
            local rc=$?
            if [[ $rc -eq 0 ]]; then
                _frosty_ok "Node '$del_n' removed"
                load_module "pm2.sh"
                local pm2_bin
                pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
                [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot >/dev/null 2>&1
            elif [[ $rc -eq 2 ]]; then
                _frosty_fail "Cannot remove the primary local node (use Rename instead)"
            else
                _frosty_fail "Node '$del_n' not found"
            fi
            ;;
        4)
            _frosty_bot_ensure_ssh_key
            echo ""
            echo -e "  ${C_CYAN:-}Bot SSH Public Key:${C_RESET:-}"
            cat "${FROSTY_VPSBOT_DIR}/frosty_node_key.pub" 2>/dev/null
            echo ""
            ;;
        *) return 0 ;;
    esac
}

install_vps_bot() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Multi-Node VPS Discord Bot ==${C_RESET:-}"

    echo "    Installing base requirements..."
    dpkg --configure -a >/tmp/frosty_vpsbot_dpkg.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_vpsbot_apt.log 2>&1
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y git nano python3 python3-pip python3-venv sshpass openssh-client openssh-server curl >>/tmp/frosty_vpsbot_apt.log 2>&1; then
        _frosty_fail "Base package install failed — see /tmp/frosty_vpsbot_apt.log"
        return 1
    fi
    _frosty_ok "git/python3/venv/sshpass installed"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "    Installing Docker..."
        load_module "docker.sh"
        if ! install_docker; then
            _frosty_fail "Docker install failed"
            return 1
        fi
    else
        _frosty_ok "Docker already available"
    fi

    local backup_tmp="/tmp/frosty_vpsbot_backup_$$"
    if [[ -d "$FROSTY_VPSBOT_DIR" ]]; then
        _frosty_warn "Existing installation found — backing up data & re-cloning fresh"
        mkdir -p "$backup_tmp"
        for data_f in user_data.json vps_data.json admin_data.json invite_data.json nodes_data.json frosty_node_key frosty_node_key.pub; do
            if [[ -f "${FROSTY_VPSBOT_DIR}/${data_f}" ]]; then
                cp -a "${FROSTY_VPSBOT_DIR}/${data_f}" "${backup_tmp}/" 2>/dev/null
            fi
        done
        load_module "pm2.sh"
        local pm2_bin
        pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" delete vps-bot >/dev/null 2>&1
        rm -rf "$FROSTY_VPSBOT_DIR"
    fi

    echo "    Cloning Frosty-vps-bot..."
    if ! timeout 60 git clone https://github.com/Ronak-gaming/Frosty-vps-bot.git "$FROSTY_VPSBOT_DIR" >/tmp/frosty_vpsbot_clone.log 2>&1; then
        _frosty_fail "Clone failed — see /tmp/frosty_vpsbot_clone.log"
        rm -rf "$backup_tmp"
        return 1
    fi
    _frosty_ok "Cloned to ${FROSTY_VPSBOT_DIR}"

    if [[ -d "$backup_tmp" ]]; then
        cp -a "${backup_tmp}/." "$FROSTY_VPSBOT_DIR/" 2>/dev/null
        rm -rf "$backup_tmp"
        _frosty_ok "Restored existing VPS database, credits, and paired nodes"
    fi

    cd "$FROSTY_VPSBOT_DIR" || return 1

    echo "    Setting up Python virtual environment..."
    python3 -m venv venv >/tmp/frosty_vpsbot_venv.log 2>&1
    if ! ./venv/bin/pip install -U discord.py >>/tmp/frosty_vpsbot_venv.log 2>&1; then
        _frosty_fail "pip install discord.py failed — see /tmp/frosty_vpsbot_venv.log"
        return 1
    fi
    _frosty_ok "Virtual environment ready"

    _frosty_bot_ensure_ssh_key

    echo ""
    echo -e "${C_CYAN:-}== Bot & Multi-Node Configuration ==${C_RESET:-}"
    read -rp "  Your Discord user ID (MAIN_ADMIN_ID): " admin_id
    admin_id="${admin_id//[[:space:]]/}"
    if [[ -z "$admin_id" || ! "$admin_id" =~ ^[0-9]+$ ]]; then
        _frosty_fail "Admin ID must be numeric"
        return 1
    fi

    read -rsp "  Bot token (from Discord Developer Portal -> Bot -> Token): " bot_token
    echo ""
    bot_token="${bot_token//[[:space:]]/}"
    if [[ -z "$bot_token" ]]; then
        _frosty_fail "Token is required"
        return 1
    fi

    if _frosty_detect_bot_from_token "$bot_token"; then
        _frosty_ok "Auto-Detected Discord Bot: ${DETECTED_BOT_NAME} (ID: ${DETECTED_BOT_ID})"
    fi

    read -rp "  Enter a name for THIS Primary Node [default: Node-1]: " primary_node_name
    primary_node_name="$(echo "${primary_node_name:-Node-1}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$primary_node_name" ]] && primary_node_name="Node-1"

    local local_pub_ip
    local_pub_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo '127.0.0.1')}"

    if [[ -f config.py ]]; then
        grep -q "MAIN_ADMIN_ID" config.py && sed -i "s/MAIN_ADMIN_ID[[:space:]]*=.*/MAIN_ADMIN_ID = ${admin_id}/" config.py
        grep -q "LOCAL_NODE_NAME" config.py && sed -i "s/LOCAL_NODE_NAME[[:space:]]*=.*/LOCAL_NODE_NAME = \"${primary_node_name}\"/" config.py
        grep -q "SERVER_PUBLIC_IP" config.py && sed -i "s/SERVER_PUBLIC_IP[[:space:]]*=.*/SERVER_PUBLIC_IP = \"${local_pub_ip}\"/" config.py
    fi

    _frosty_bot_register_node_json "$primary_node_name" "true" "$local_pub_ip" "22"
    _frosty_ok "Registered Primary Node '${primary_node_name}' (${local_pub_ip}) in nodes_data.json"

    cat > "${FROSTY_VPSBOT_DIR}/start.sh" << STARTEOF
#!/usr/bin/env bash
cd "${FROSTY_VPSBOT_DIR}"
export DISCORD_BOT_TOKEN="${bot_token}"
source venv/bin/activate
exec python3 main.py
STARTEOF
    chmod +x "${FROSTY_VPSBOT_DIR}/start.sh"
    chmod 600 "${FROSTY_VPSBOT_DIR}/start.sh"

    echo ""
    read -rp "  Do you want to pair Node-2 (Remote Worker VPS) right now from terminal? [y/N]: " pair_more
    while [[ "$pair_more" =~ ^[Yy]$ ]]; do
        add_vps_bot_remote_node || true
        echo ""
        read -rp "  Pair another Remote VPS Node? [y/N]: " pair_more
    done

    echo "    Starting the bot under pm2..."
    load_module "pm2.sh"
    _frosty_ensure_pm2_always
    _frosty_pm2_start "vps-bot" "$FROSTY_VPSBOT_DIR" "bash" "start.sh"

    _frosty_ok "VPS Discord bot is online with '${primary_node_name}'!"
    return 0
}

show_vps_bot_submenu() {
    clear
    print_banner
    echo -e "${C_FROST:-}${C_BOLD:-}╔══════════════════════════════════════════════╗${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}      ${C_ICE:-}${C_BOLD:-}❄  M U L T I - N O D E   B O T  ❄${C_RESET:-}       ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╠══════════════════════════════════════════════╣${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}                                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_CYAN:-}[1]${C_RESET:-} ${C_WHITE:-}Install / Reinstall Bot (Primary Host)${C_RESET:-}   ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_GREEN:-}[2]${C_RESET:-} ${C_WHITE:-}Add / Pair Remote VPS Node (Terminal)${C_RESET:-}    ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_YELLOW:-}[3]${C_RESET:-} ${C_WHITE:-}Setup THIS Server as Worker Node${C_RESET:-}         ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_ICE:-}[4]${C_RESET:-} ${C_WHITE:-}Manage Nodes (List / Rename / Remove)${C_RESET:-}    ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_PURPLE:-}[5]${C_RESET:-} ${C_WHITE:-}Restart Bot${C_RESET:-}                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_ICE:-}[6]${C_RESET:-} ${C_WHITE:-}View Bot Logs${C_RESET:-}                            ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}  ${C_BLUE:-}[7]${C_RESET:-} ${C_WHITE:-}Back to Main Menu${C_RESET:-}                        ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}║${C_RESET:-}                                              ${C_FROST:-}${C_BOLD:-}║${C_RESET:-}"
    echo -e "${C_FROST:-}${C_BOLD:-}╚══════════════════════════════════════════════╝${C_RESET:-}"
    echo ""
    read -rp "  ❄ Select an option [1-7]: " bot_choice

    load_module "pm2.sh"
    local pm2_bin
    pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
    case "$bot_choice" in
        1) install_vps_bot ;;
        2) add_vps_bot_remote_node ;;
        3) prepare_this_server_as_worker_node ;;
        4) manage_vps_bot_nodes_cli ;;
        5) [[ -n "$pm2_bin" ]] && "$pm2_bin" restart vps-bot && _frosty_ok "Restarted" || _frosty_fail "pm2 not found" ;;
        6) [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 30 --nostream || _frosty_fail "pm2 not found" ;;
        7) return 0 ;;
        *) echo -e "${C_RED:-}Invalid option.${C_RESET:-}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_bot_submenu
}

run_vps_bot_flow() {
    show_vps_bot_submenu
}
