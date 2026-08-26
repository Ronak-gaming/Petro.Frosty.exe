#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPS_DOCKER_DIR="/var/lib/frosty-vps-docker"

install_vps_docker_stack() {
    echo ""
    echo "== Setting Up Docker-based VPS (no KVM available) =="

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo "    Installing Docker..."
        curl -fsSL https://get.docker.com | sh >/tmp/frosty_vps_docker_install.log 2>&1
        if [[ -d /run/systemd/system ]]; then
            systemctl enable --now docker >/dev/null 2>&1
        else
            dockerd >/tmp/frosty_vps_dockerd.log 2>&1 &
            sleep 5
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        _frosty_fail "Docker is not available — cannot set up VPS containers"
        return 1
    fi
    _frosty_ok "Docker available"

    mkdir -p "$FROSTY_VPS_DOCKER_DIR"

    if [[ ! -f "${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key" ]]; then
        echo "    Generating SSH keypair for automated container access..."
        ssh-keygen -t ed25519 -f "${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key" -N "" -C "frosty-vps-docker" >/dev/null 2>&1
        chmod 600 "${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key"
        _frosty_ok "SSH keypair generated"
    fi

    _frosty_warn "Note: this is container-based, not true KVM virtualization (shares host kernel)"
    return 0
}

_frosty_vps_docker_image() {
    case "$1" in
        ubuntu2604) echo "ubuntu:26.04" ;;
        ubuntu2404) echo "ubuntu:24.04" ;;
        ubuntu2204) echo "ubuntu:22.04" ;;
        debian11) echo "debian:11" ;;
        debian12) echo "debian:12" ;;
        debian13) echo "debian:13" ;;
        *) echo "" ;;
    esac
}

vps_docker_exists_any() {
    command -v docker >/dev/null 2>&1 && docker ps -a --filter "name=frosty-vps-" -q 2>/dev/null | grep -q .
}

# Returns the published host SSH port for a VPS by reading its .meta file,
# falling back to inspecting the live container if the meta is missing/old.
_frosty_vps_docker_ssh_port() {
    local vm_name="$1"
    local meta="${FROSTY_VPS_DOCKER_DIR}/${vm_name}.meta"
    local port=""

    if [[ -f "$meta" ]]; then
        port="$(grep -E '^ssh_port=' "$meta" 2>/dev/null | cut -d= -f2)"
    fi

    if [[ -z "$port" ]]; then
        port="$(docker port "frosty-vps-${vm_name}" 22/tcp 2>/dev/null | head -1 | cut -d: -f2)"
    fi

    echo "$port"
}

show_vps_docker_menu() {
    clear
    print_banner

    if vps_docker_exists_any; then
        show_vps_docker_full_menu
        return 0
    fi

    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄  D O C K E R   V P S  ❄${C_RESET}          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Create VPS${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[2]${C_RESET} ${C_WHITE}Back${C_RESET}                                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-2]: " gate_choice

    case "$gate_choice" in
        1)
            if ! install_vps_docker_stack; then
                echo ""
                echo -e "${C_YELLOW}Docker setup failed on this host.${C_RESET}"
                echo ""
                read -rp "  Press Enter to continue..." _
                return 1
            fi
            vps_docker_create
            ;;
        2) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_docker_menu
}

vps_docker_create() {
    echo ""
    echo -e "${C_CYAN:-}== Create New VPS (Docker) ==${C_RESET:-}"
    echo ""
    read -rp "  VPS name (e.g. client1-vps): " vm_name
    [[ -z "$vm_name" ]] && { _frosty_fail "Name required"; return 1; }

    if docker inspect "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_fail "A VPS named '$vm_name' already exists"
        return 1
    fi

    echo "  Image: [1] Ubuntu 26.04 LTS  [2] Ubuntu 24.04 LTS  [3] Ubuntu 22.04 LTS"
    echo "         [4] Debian 11  [5] Debian 12  [6] Debian 13"
    read -rp "  Choice [1-6]: " img_choice
    case "$img_choice" in
        1) img_key="ubuntu2604" ;;
        2) img_key="ubuntu2404" ;;
        3) img_key="ubuntu2204" ;;
        4) img_key="debian11" ;;
        5) img_key="debian12" ;;
        6) img_key="debian13" ;;
        *) _frosty_fail "Invalid image choice"; return 1 ;;
    esac
    local docker_img
    docker_img="$(_frosty_vps_docker_image "$img_key")"

    echo "  Resource preset: [1] Small (1 CPU/1GB)  [2] Medium (2 CPU/2GB)  [3] Large (4 CPU/4GB)  [4] Custom"
    read -rp "  Choice [1-4]: " preset_choice
    case "$preset_choice" in
        1) vm_cpu=1; vm_ram=1024 ;;
        2) vm_cpu=2; vm_ram=2048 ;;
        3) vm_cpu=4; vm_ram=4096 ;;
        4)
            read -rp "  RAM in MB: " vm_ram
            read -rp "  CPU cores: " vm_cpu
            ;;
        *) _frosty_fail "Invalid preset choice"; return 1 ;;
    esac
    vm_ram="$(echo "$vm_ram" | tr -cd '0-9')"
    vm_cpu="$(echo "$vm_cpu" | tr -cd '0-9')"
    if [[ -z "$vm_ram" || -z "$vm_cpu" ]]; then
        _frosty_fail "RAM and CPU must be numbers"
        return 1
    fi

    read -rsp "  Set root password: " vm_pass
    echo ""
    if [[ -z "$vm_pass" ]]; then
        _frosty_fail "Root password is required"
        return 1
    fi

    local pubkey
    pubkey="$(cat "${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key.pub" 2>/dev/null)"

    # Find a free host port for SSH, starting at 2200 — this is what was
    # missing before: without publishing a port, nothing outside the
    # container could ever reach its sshd.
    local ssh_port=2200
    while docker ps -a --format '{{.Ports}}' | grep -q ":${ssh_port}->"; do
        ssh_port=$((ssh_port + 1))
    done

    echo "    Pulling image ${docker_img}..."
    docker pull "$docker_img" >/tmp/frosty_vps_docker_pull.log 2>&1

    echo "    Creating container (SSH will be reachable on host port ${ssh_port})..."
    docker run -d \
        --name "frosty-vps-${vm_name}" \
        --hostname "$vm_name" \
        --memory "${vm_ram}m" \
        --cpus "$vm_cpu" \
        --restart unless-stopped \
        -p "${ssh_port}:22" \
        "$docker_img" sleep infinity >/tmp/frosty_vps_docker_run.log 2>&1

    if [[ $? -ne 0 ]]; then
        _frosty_fail "Container creation failed — see /tmp/frosty_vps_docker_run.log"
        return 1
    fi
    _frosty_ok "Container 'frosty-vps-${vm_name}' created"

    echo "    Installing SSH server inside container..."
    docker exec "frosty-vps-${vm_name}" bash -c "
        apt update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt install -y openssh-server sudo curl >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt install -y neofetch >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt install -y screenfetch >/dev/null 2>&1
        mkdir -p /run/sshd /root/.ssh
        echo 'root:${vm_pass}' | chpasswd
        echo '${pubkey}' >> /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        ssh-keygen -A >/dev/null 2>&1
        /usr/sbin/sshd
    " >/tmp/frosty_vps_docker_ssh_setup.log 2>&1

    if [[ $? -ne 0 ]]; then
        _frosty_fail "SSH setup inside container failed — see /tmp/frosty_vps_docker_ssh_setup.log"
        return 1
    fi

    # Verify sshd actually stayed running before declaring success — some
    # minimal base images silently refuse to start sshd if host keys are
    # missing, so a clean exit code alone isn't proof it's really up.
    sleep 1
    if ! docker exec "frosty-vps-${vm_name}" pgrep -x sshd >/dev/null 2>&1; then
        _frosty_fail "sshd did not stay running inside the container — see /tmp/frosty_vps_docker_ssh_setup.log"
        return 1
    fi
    _frosty_ok "SSH server running inside container (host port ${ssh_port} -> container 22)"

    cat > "${FROSTY_VPS_DOCKER_DIR}/${vm_name}.meta" << METAEOF
image=${img_key}
container=frosty-vps-${vm_name}
created=$(date '+%Y-%m-%d %H:%M:%S')
ssh_port=${ssh_port}
METAEOF

    echo ""
    echo -e "    ${C_CYAN:-}Connect via SSH with:${C_RESET:-}"
    echo "      ssh -i ${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key -p ${ssh_port} root@${FROSTY_PUBLIC_IP:-<your-server-ip>}"

    echo ""
    echo "  Access this VPS now? [1] tmate (shareable link)  [2] Live Terminal (local, opens now)  [3] Skip"
    read -rp "  Choice [1-3]: " share_now
    case "$share_now" in
        1) vps_docker_share_tmate <<< "$vm_name" ;;
        2) vps_docker_live_terminal <<< "$vm_name" ;;
        *) : ;;
    esac

    return 0
}

vps_docker_list() {
    echo ""
    echo "== VPS Instances (Docker) =="
    docker ps -a --filter "name=frosty-vps-" --format "table {{.Names}}\t{{.Status}}"
}

vps_docker_start() {
    echo ""
    read -rp "  VPS name to start: " vm_name
    if docker start "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_ok "'$vm_name' started"
    else
        _frosty_fail "Start failed"
        return 1
    fi
}

vps_docker_stop() {
    echo ""
    read -rp "  VPS name to stop: " vm_name
    if docker stop "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_ok "'$vm_name' stopped"
    else
        _frosty_fail "Stop failed"
        return 1
    fi
}

vps_docker_delete() {
    echo ""
    read -rp "  VPS name to DELETE: " vm_name
    read -rp "  Type DELETE to confirm: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        echo "Cancelled."
        return 1
    fi
    docker rm -f "frosty-vps-${vm_name}" >/dev/null 2>&1
    rm -f "${FROSTY_VPS_DOCKER_DIR}/${vm_name}.meta"
    _frosty_ok "'$vm_name' deleted"
}

vps_docker_dashboard() {
    echo ""
    echo -e "${C_CYAN:-}== VPS Resource Dashboard (Docker) ==${C_RESET:-}"
    docker stats --no-stream --filter "name=frosty-vps-" --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
}

vps_docker_edit_config() {
    echo ""
    read -rp "  VPS name to edit: " vm_name
    if ! docker inspect "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_fail "VPS '$vm_name' not found"
        return 1
    fi

    echo "  [1] Change RAM  [2] Change CPU limit"
    read -rp "  Choice: " edit_choice
    case "$edit_choice" in
        1)
            read -rp "  New RAM in MB: " new_ram
            new_ram="$(echo "$new_ram" | tr -cd '0-9')"
            docker update --memory "${new_ram}m" --memory-swap "${new_ram}m" "frosty-vps-${vm_name}" >/dev/null 2>&1
            _frosty_ok "RAM updated to ${new_ram}MB"
            ;;
        2)
            read -rp "  New CPU limit (cores): " new_cpu
            new_cpu="$(echo "$new_cpu" | tr -cd '0-9')"
            docker update --cpus "$new_cpu" "frosty-vps-${vm_name}" >/dev/null 2>&1
            _frosty_ok "CPU limit updated to ${new_cpu}"
            ;;
        *) _frosty_fail "Invalid choice" ;;
    esac
}

# Opens a direct, interactive shell into the container right in the current
# terminal — no tmate, no shareable link, just an immediate live session
# for the person sitting at this machine.
vps_docker_live_terminal() {
    echo ""
    echo -e "${C_CYAN:-}== Live Terminal (Local) ==${C_RESET:-}"
    read -rp "  VPS name to open: " vm_name

    if ! docker inspect "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_fail "VPS '$vm_name' not found"
        return 1
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "frosty-vps-${vm_name}" 2>/dev/null)" != "true" ]]; then
        _frosty_warn "'$vm_name' is not running — starting it first..."
        docker start "frosty-vps-${vm_name}" >/dev/null 2>&1
        sleep 1
    fi

    echo -e "    ${C_YELLOW:-}Opening a live terminal into '$vm_name'. Type 'exit' to return to Frosty.exe.${C_RESET:-}"
    echo ""
    docker exec -it "frosty-vps-${vm_name}" bash -c "command -v neofetch >/dev/null 2>&1 && neofetch || (command -v screenfetch >/dev/null 2>&1 && screenfetch); exec bash -l"
    echo ""
    _frosty_ok "Returned from live terminal into '$vm_name'"
}

vps_docker_share_tmate() {
    echo ""
    echo "== Share Terminal via tmate =="
    read -rp "  VPS name to access: " vm_name

    if ! docker inspect "frosty-vps-${vm_name}" >/dev/null 2>&1; then
        _frosty_fail "VPS '$vm_name' not found"
        return 1
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "frosty-vps-${vm_name}" 2>/dev/null)" != "true" ]]; then
        _frosty_warn "'$vm_name' is not running — starting it first..."
        docker start "frosty-vps-${vm_name}" >/dev/null 2>&1
        sleep 1
    fi

    if ! command -v tmate >/dev/null 2>&1; then
        echo "    Installing tmate..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_tmate_install.log 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmate >>/tmp/frosty_tmate_install.log 2>&1
        if ! command -v tmate >/dev/null 2>&1; then
            _frosty_fail "tmate install failed — see /tmp/frosty_tmate_install.log"
            return 1
        fi
    fi

    local tmate_sock="/tmp/frosty-tmate-docker-${vm_name}.sock"
    local ssh_line=""

    # Checking exit code alone isn't enough — a stale local socket from a
    # session whose link never actually populated (e.g. hit before this
    # fix, or a network hiccup) still returns exit 0 with an empty value.
    ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"
    if [[ -n "$ssh_line" ]]; then
        _frosty_ok "Existing tmate session for '$vm_name' is still alive — reusing it"
    else
        if [[ -S "$tmate_sock" ]]; then
            _frosty_warn "Found a stale/dead tmate socket for '$vm_name' — cleaning it up and starting fresh"
            tmate -S "$tmate_sock" kill-server >/dev/null 2>&1
        fi
        echo -e "    ${C_CYAN:-}Starting a new tmate session into VPS '$vm_name'...${C_RESET:-}"
        rm -f "$tmate_sock"
        tmate -S "$tmate_sock" -f /dev/null new-session -d -n frosty-vps-docker \
            "docker exec -it frosty-vps-${vm_name} bash -c 'command -v neofetch >/dev/null 2>&1 && neofetch || screenfetch; exec bash -l'" \
            2>/tmp/frosty_tmate_session.log

        if [[ $? -ne 0 ]]; then
            _frosty_fail "tmate failed to start a session — see /tmp/frosty_tmate_session.log"
            return 1
        fi

        # Poll instead of a blind sleep — tmate needs a variable amount of
        # time to reach its server and generate the link, and a fixed
        # sleep 3 was frequently too short, leaving the link blank.
        echo -n "    Waiting for tmate to establish the session"
        local waited=0
        while [[ ${waited} -lt 20 ]]; do
            ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"
            if [[ -n "$ssh_line" ]]; then
                break
            fi
            echo -n "."
            sleep 1
            waited=$((waited + 1))
        done
        echo ""

        if [[ -z "$ssh_line" ]]; then
            _frosty_fail "tmate session did not come up after ${waited}s — is this host able to reach tmate.io?"
            _frosty_warn "Check /tmp/frosty_tmate_session.log, and confirm outbound network access is allowed."
            return 1
        fi
    fi

    echo ""
    echo -e "    ${C_YELLOW:-}Anyone with the link/command below gets a live terminal into '$vm_name':${C_RESET:-}"
    tmate -S "$tmate_sock" display -p '#{tmate_ssh}'
    tmate -S "$tmate_sock" display -p '#{tmate_web}'
}

vps_docker_rejoin_tmate() {
    echo ""
    echo "== Rejoin Existing tmate Session =="
    read -rp "  VPS name: " vm_name
    local tmate_sock="/tmp/frosty-tmate-docker-${vm_name}.sock"
    local ssh_line=""

    if [[ -S "$tmate_sock" ]]; then
        ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"
    fi

    if [[ -z "$ssh_line" ]]; then
        _frosty_warn "No live tmate session found for '$vm_name' — starting a new one instead"
        [[ -S "$tmate_sock" ]] && tmate -S "$tmate_sock" kill-server >/dev/null 2>&1
        rm -f "$tmate_sock"
        vps_docker_share_tmate <<< "$vm_name"
        return 0
    fi

    echo -e "    ${C_CYAN:-}Session is alive. Sharing details for '$vm_name':${C_RESET:-}"
    echo "$ssh_line"
    tmate -S "$tmate_sock" display -p '#{tmate_web}' 2>/dev/null
}

show_vps_docker_full_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}   ${C_ICE}${C_BOLD}❄  V P S   ( D O C K E R   M O D E )  ❄${C_RESET}   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET}  ${C_WHITE}Set Up VPS${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[2]${C_RESET}  ${C_WHITE}List VPS${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[3]${C_RESET}  ${C_WHITE}Resource Dashboard${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[4]${C_RESET}  ${C_WHITE}Start VPS${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_YELLOW}[5]${C_RESET}  ${C_WHITE}Stop VPS${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[6]${C_RESET}  ${C_WHITE}Edit VPS Config${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[7]${C_RESET}  ${C_WHITE}Delete VPS${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[8]${C_RESET}  ${C_WHITE}Share via tmate${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[9]${C_RESET}  ${C_WHITE}Rejoin tmate Session${C_RESET}                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[10]${C_RESET} ${C_WHITE}Live Terminal (Local)${C_RESET}                   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[11]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-11]: " vps_choice

    case "$vps_choice" in
        1) vps_docker_create ;;
        2) vps_docker_list ;;
        3) vps_docker_dashboard ;;
        4) vps_docker_start ;;
        5) vps_docker_stop ;;
        6) vps_docker_edit_config ;;
        7) vps_docker_delete ;;
        8) vps_docker_share_tmate ;;
        9) vps_docker_rejoin_tmate ;;
        10) vps_docker_live_terminal ;;
        11) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_docker_full_menu
}
