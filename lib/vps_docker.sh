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

    read -rp "  SSH port to expose on host (e.g. 2201): " vm_sshport
    vm_sshport="$(echo "$vm_sshport" | tr -cd '0-9')"
    if [[ -z "$vm_sshport" ]]; then
        _frosty_fail "SSH port is required"
        return 1
    fi

    read -rp "  Set root password: " vm_pass
    if [[ -z "$vm_pass" ]]; then
        _frosty_fail "Root password is required"
        return 1
    fi

    local pubkey
    pubkey="$(cat "${FROSTY_VPS_DOCKER_DIR}/frosty_vps_key.pub" 2>/dev/null)"

    echo "    Pulling image ${docker_img}..."
    docker pull "$docker_img" >/tmp/frosty_vps_docker_pull.log 2>&1

    echo "    Creating container..."
    docker run -d \
        --name "frosty-vps-${vm_name}" \
        --hostname "$vm_name" \
        --memory "${vm_ram}m" \
        --cpus "$vm_cpu" \
        -p "${vm_sshport}:22" \
        --restart unless-stopped \
        "$docker_img" sleep infinity >/tmp/frosty_vps_docker_run.log 2>&1

    if [[ $? -ne 0 ]]; then
        _frosty_fail "Container creation failed — see /tmp/frosty_vps_docker_run.log"
        return 1
    fi
    _frosty_ok "Container 'frosty-vps-${vm_name}' created"

    echo "    Installing SSH server inside container..."
    docker exec "frosty-vps-${vm_name}" bash -c "
        apt update -y >/dev/null 2>&1
        apt install -y openssh-server sudo curl >/dev/null 2>&1
        mkdir -p /run/sshd /root/.ssh
        echo 'root:${vm_pass}' | chpasswd
        echo '${pubkey}' >> /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        /usr/sbin/sshd
    " >/tmp/frosty_vps_docker_ssh_setup.log 2>&1

    if [[ $? -ne 0 ]]; then
        _frosty_fail "SSH setup inside container failed — see /tmp/frosty_vps_docker_ssh_setup.log"
        return 1
    fi
    _frosty_ok "SSH server running inside container"

    cat > "${FROSTY_VPS_DOCKER_DIR}/${vm_name}.meta" << METAEOF
image=${img_key}
ssh_port=${vm_sshport}
container=frosty-vps-${vm_name}
created=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    echo ""
    echo -e "    ${C_CYAN:-}VPS ready. Access it via:${C_RESET:-}"
    echo -e "    ${C_CYAN:-}  ssh root@$(curl -s ifconfig.me 2>/dev/null || echo YOUR_HOST_IP) -p ${vm_sshport}${C_RESET:-}"
    return 0
}

vps_docker_list() {
    echo ""
    echo "== VPS Instances (Docker) =="
    docker ps -a --filter "name=frosty-vps-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
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

show_vps_docker_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}   ${C_ICE}${C_BOLD}❄  V P S   ( D O C K E R   M O D E )  ❄${C_RESET}   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Set Up VPS${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[2]${C_RESET} ${C_WHITE}List VPS${C_RESET}                                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[3]${C_RESET} ${C_WHITE}Resource Dashboard${C_RESET}                       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[4]${C_RESET} ${C_WHITE}Start VPS${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_YELLOW}[5]${C_RESET} ${C_WHITE}Stop VPS${C_RESET}                                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[6]${C_RESET} ${C_WHITE}Delete VPS${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[7]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-7]: " vps_choice

    case "$vps_choice" in
        1) install_vps_docker_stack && vps_docker_create ;;
        2) vps_docker_list ;;
        3) vps_docker_dashboard ;;
        4) vps_docker_start ;;
        5) vps_docker_stop ;;
        6) vps_docker_delete ;;
        7) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_docker_submenu
}
