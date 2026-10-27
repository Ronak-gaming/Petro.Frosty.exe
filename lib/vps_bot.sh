#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPSBOT_DIR="/opt/Frosty-vps-bot"

vps_bot_installed() {
    [[ -f "${FROSTY_VPSBOT_DIR}/main.py" ]]
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
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12 \
            "root@${remote_ip}" "
                mkdir -p ~/.ssh && chmod 700 ~/.ssh
                grep -qxF '${pubkey}' ~/.ssh/authorized_keys 2>/dev/null || echo '${pubkey}' >> ~/.ssh/authorized_keys
                chmod 600 ~/.ssh/authorized_keys
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

# Prepares the current machine if it is a 2nd/3rd worker VPS being controlled by a primary bot elsewhere
prepare_this_server_as_worker_node() {
    echo ""
    echo -e "${C_CYAN:-}== Prepare THIS Server as a Remote Worker Node ==${C_RESET:-}"
    echo "    Use this option if your Discord Bot runs on ANOTHER VPS, and you want"
    echo "    this VPS to act as Node 2 / Node 3 for that bot."
    echo ""

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

    echo "    Ensuring OpenSSH server and IP forwarding are enabled..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null 2>&1
    mkdir -p /run/sshd /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
    if [[ -d /run/systemd/system ]]; then
        systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    else
        pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    read -rp "  Optional — Paste the Primary Bot's SSH public key (from !node-key), or press Enter to skip: " bot_pubkey
    if [[ -n "$bot_pubkey" ]]; then
        grep -qxF "$bot_pubkey" /root/.ssh/authorized_keys 2>/dev/null || echo "$bot_pubkey" >> /root/.ssh/authorized_keys
        _frosty_ok "Primary Bot SSH key added to /root/.ssh/authorized_keys"
    fi

    local my_ip
    my_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo 'YOUR_NODE_IP')}"
    _frosty_ok "This server is ready to be controlled as a Bot Worker Node!"
    echo ""
    echo -e "  ${C_CYAN:-}Next Step — Run this command in your Discord server:${C_RESET:-}"
    if [[ -n "$bot_pubkey" ]]; then
        echo -e "    ${C_WHITE}!node-add Node-2 ${my_ip} 22 KEY_ONLY${C_RESET}"
    else
        echo -e "    ${C_WHITE}!node-add Node-2 ${my_ip} 22 <this_server_root_password>${C_RESET}"
    fi
}

manage_vps_bot_nodes_cli() {
    echo ""
    echo -e "${C_CYAN:-}== Registered Bot Nodes ==${C_RESET:-}"
    local nodes_file="${FROSTY_VPSBOT_DIR}/nodes_data.json"
    if [[ ! -f "$nodes_file" ]]; then
        _frosty_warn "No nodes_data.json found yet — install the bot first."
        return 1
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
    echo "  [1] Add / Pair a New Remote Node"
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
    print("ERR_NOT_FOUND")
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
            echo -e "  ${C_CYAN:-}Bot SSH Public Key (paste into /root/.ssh/authorized_keys on remote nodes):${C_RESET:-}"
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
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y git nano python3 python3-pip python3-venv sshpass openssh-client >>/tmp/frosty_vpsbot_apt.log 2>&1; then
        _frosty_fail "Base package install failed — see /tmp/frosty_vpsbot_apt.log"
        return 1
    fi
    _frosty_ok "git/python3/venv/sshpass installed"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "    Installing Docker (the bot manages VPS containers via it)..."
        load_module "docker.sh"
        if ! install_docker; then
            _frosty_fail "Docker install failed — the bot needs it to create/manage VPS containers"
            return 1
        fi
    else
        _frosty_ok "Docker already available"
    fi

    # Back up any existing JSON data & SSH keys before wiping for a fresh clone
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

    # Restore preserved JSON state and SSH keypair if reinstalling
    if [[ -d "$backup_tmp" ]]; then
        cp -a "${backup_tmp}/." "$FROSTY_VPSBOT_DIR/" 2>/dev/null
        rm -rf "$backup_tmp"
        _frosty_ok "Restored existing VPS database, credits, and paired nodes"
    fi

    cd "$FROSTY_VPSBOT_DIR" || return 1
    for f in main.py config.py storage.py docker_utils.py views.py; do
        if [[ ! -f "$f" ]]; then
            _frosty_warn "Expected file missing after clone: $f — bot may not run correctly"
        fi
    done

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
        _frosty_fail "Admin ID must be numeric (right-click your Discord profile -> Copy User ID)"
        return 1
    fi

    read -rsp "  Bot token (from Discord Developer Portal -> Bot -> Token): " bot_token
    echo ""
    if [[ -z "$bot_token" ]]; then
        _frosty_fail "Token is required"
        return 1
    fi

    read -rp "  Enter a custom name for THIS Primary Node [default: Node-1]: " primary_node_name
    primary_node_name="$(echo "${primary_node_name:-Node-1}" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$primary_node_name" ]] && primary_node_name="Node-1"

    local local_pub_ip
    local_pub_ip="${FROSTY_PUBLIC_IP:-$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo '127.0.0.1')}"

    if [[ -f config.py ]]; then
        grep -q "MAIN_ADMIN_ID" config.py && sed -i "s/MAIN_ADMIN_ID[[:space:]]*=.*/MAIN_ADMIN_ID = ${admin_id}/" config.py
        if grep -q "LOCAL_NODE_NAME" config.py; then
            sed -i "s/LOCAL_NODE_NAME[[:space:]]*=.*/LOCAL_NODE_NAME = \"${primary_node_name}\"/" config.py
        fi
        if grep -q 'SERVER_PUBLIC_IP[[:space:]]*=[[:space:]]*"YOUR_SERVER_IP"' config.py; then
            sed -i "s/SERVER_PUBLIC_IP[[:space:]]*=[[:space:]]*\"YOUR_SERVER_IP\"/SERVER_PUBLIC_IP = \"${local_pub_ip}\"/" config.py
        fi
        _frosty_ok "MAIN_ADMIN_ID and Primary Node '${primary_node_name}' written to config.py"
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
    _frosty_ok "Token configured (stored in start.sh, permissions locked to root-only)"

    echo ""
    read -rp "  Do you want to pair a 2nd Remote VPS Node right now? [y/N]: " pair_more
    while [[ "$pair_more" =~ ^[Yy]$ ]]; do
        add_vps_bot_remote_node || true
        echo ""
        read -rp "  Pair another Remote VPS Node? [y/N]: " pair_more
    done

    echo "    Starting the bot under pm2..."
    load_module "pm2.sh"
    if ! _frosty_ensure_pm2_always; then
        _frosty_fail "pm2 setup failed — cannot start the bot persistently"
        return 1
    fi
    if ! _frosty_pm2_start "vps-bot" "$FROSTY_VPSBOT_DIR" "bash" "start.sh"; then
        echo "    pm2 logs:"
        local pm2_bin
        pm2_bin="$(_frosty_pm2_bin 2>/dev/null)"
        [[ -n "$pm2_bin" ]] && "$pm2_bin" logs vps-bot --lines 20 --nostream 2>/dev/null
        return 1
    fi

    _frosty_ok "VPS Discord bot running with Multi-Node support! Try !nodes or !help in your Discord server."
    return 0
}

show_vps_bot_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}      ${C_ICE}${C_BOLD}❄  M U L T I - N O D E   B O T  ❄${C_RESET}       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Install / Reinstall Bot (Primary Host)${C_RESET}    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[2]${C_RESET} ${C_WHITE}Add / Pair Remote VPS Node${C_RESET}                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_YELLOW}[3]${C_RESET} ${C_WHITE}Setup THIS Server as Worker Node${C_RESET}          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[4]${C_RESET} ${C_WHITE}Manage Nodes (List / Rename / Remove)${C_RESET}     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[5]${C_RESET} ${C_WHITE}Restart Bot${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[6]${C_RESET} ${C_WHITE}View Bot Logs${C_RESET}                             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[7]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
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
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_bot_submenu
}

run_vps_bot_flow() {
    show_vps_bot_submenu
}
