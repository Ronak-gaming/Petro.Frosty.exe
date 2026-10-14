#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# KVM VPS — rewritten to use QEMU directly instead of libvirt.
# ============================================================

FROSTY_VPS_DIR="/var/lib/frosty-vps"
FROSTY_VPS_IMG_DIR="${FROSTY_VPS_DIR}/images"
FROSTY_VPS_SNAP_DIR="${FROSTY_VPS_DIR}/snapshots"

_frosty_vps_check_stack() {
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        _frosty_warn "QEMU not installed yet — run Create VPS first"
        return 1
    fi
    return 0
}

_frosty_vps_fix_kvm_perms() {
    if [[ -e /dev/kvm ]]; then
        chmod 666 /dev/kvm 2>/dev/null
    fi
}

_frosty_vps_kvm_usable() {
    _frosty_vps_fix_kvm_perms
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        echo 1
    else
        echo 0
    fi
}

install_vps_stack() {
    echo ""
    echo "== Installing QEMU VPS Stack =="

    rm -f /tmp/frosty_vps_dpkg_fix.log /tmp/frosty_vps_apt.log \
          /tmp/frosty_vps_download.log /tmp/frosty_vps_disk.log \
          /tmp/frosty_vps_iso.log 2>/dev/null

    dpkg --configure -a >/tmp/frosty_vps_dpkg_fix.log 2>&1

    local kvm_usable
    kvm_usable="$(_frosty_vps_kvm_usable)"
    if [[ "$kvm_usable" -eq 1 ]]; then
        _frosty_ok "/dev/kvm present and usable — VMs will use hardware acceleration"
    else
        _frosty_warn "/dev/kvm not usable on this host — real VMs here would run in slow software emulation (TCG)"
        echo ""
        echo "  No hardware virtualization available. Choose how to proceed:"
        echo "  [1] Continue anyway with software emulation (TCG) — slower, but a real isolated VM"
        echo "  [2] Switch to Docker VPS instead — near-native speed, but shares the host kernel (less isolated)"
        read -erp "  Choice [1-2]: " kvm_fallback_choice

        if [[ "$kvm_fallback_choice" == "2" ]]; then
            echo ""
            echo "    Switching to Docker VPS..."
            load_module "vps_docker.sh"
            if install_vps_docker_stack; then
                vps_docker_create
                return 2
            else
                _frosty_warn "Docker isn't available/working on this host either"
                _frosty_warn "Falling back to software-emulated (TCG) KVM VPS instead — it's slower, but it will work"
            fi
        fi
    fi

    local pkgs=(qemu-system-x86 qemu-utils genisoimage)
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 \vert{}\vert{} missing+=("$p")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "    Installing: ${missing[*]}"
        apt-get clean >/dev/null 2>&1
        rm -rf /var/cache/apt/archives/partial/* 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_vps_apt.log 2>&1

        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >>/tmp/frosty_vps_apt.log 2>&1; then
            _frosty_ok "QEMU stack installed"
        else
            _frosty_warn "First install attempt failed (often a transient /tmp issue) — retrying once..."
            dpkg --configure -a >>/tmp/frosty_vps_apt.log 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -f -y >>/tmp/frosty_vps_apt.log 2>&1
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >>/tmp/frosty_vps_apt.log 2>&1; then
                _frosty_ok "QEMU stack installed (on retry)"
            else
                _frosty_fail "Install failed after retry — see /tmp/frosty_vps_apt.log"
                return 1
            fi
        fi
    else
        _frosty_ok "QEMU stack already installed"
    fi

    if [[ ! -f /etc/udev/rules.d/99-frosty-kvm.rules ]]; then
        echo 'KERNEL=="kvm", MODE="0666"' > /etc/udev/rules.d/99-frosty-kvm.rules
        udevadm control --reload-rules >/dev/null 2>&1
        udevadm trigger >/dev/null 2>&1
    fi
    _frosty_vps_fix_kvm_perms

    load_module "pm2.sh"
    if ! _frosty_ensure_pm2_always; then
        _frosty_fail "pm2 setup failed — VPS instances need pm2 to run persistently in this environment"
        return 1
    fi
    _frosty_ok "pm2 ready for VM supervision"

    mkdir -p "$FROSTY_VPS_IMG_DIR" "$FROSTY_VPS_SNAP_DIR"

    if [[ ! -f "${FROSTY_VPS_DIR}/frosty_vps_key" ]]; then
        echo "    Generating SSH keypair for automated VM access..."
        ssh-keygen -t ed25519 -f "${FROSTY_VPS_DIR}/frosty_vps_key" -N "" -C "frosty-vps" >/dev/null 2>&1
        chmod 600 "${FROSTY_VPS_DIR}/frosty_vps_key"
        _frosty_ok "SSH keypair generated"
    fi
    return 0
}

_frosty_vps_image_url() {
    case "$1" in
        ubuntu2604) echo "https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img" ;;
        ubuntu2404) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
        ubuntu2204) echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
        debian11) echo "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2" ;;
        debian12) echo "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" ;;
        debian13) echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2" ;;
        *) echo "" ;;
    esac
}

_frosty_vps_sshport() {
    grep '^ssh_port=' "${FROSTY_VPS_IMG_DIR}/$1.meta" 2>/dev/null | cut -d= -f2
}

_frosty_vps_meta_get() {
    grep "^$2=" "${FROSTY_VPS_IMG_DIR}/$1.meta" 2>/dev/null | cut -d= -f2-
}

_frosty_vps_pm2_name() {
    echo "frosty-vps-$1"
}

vps_kvm_exists_any() {
    ls "${FROSTY_VPS_IMG_DIR}"/*.meta >/dev/null 2>&1
}

show_vps_kvm_menu() {
    if vps_kvm_exists_any; then
        show_vps_kvm_full_menu
        return 0
    fi

    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}            ${C_ICE}${C_BOLD}❄  K V M   V P S  ❄${C_RESET}${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}${C_CYAN}[1]${C_RESET}${C_WHITE}Create VPS${C_RESET}${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}${C_BLUE}[2]${C_RESET}${C_WHITE}Back${C_RESET}${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  Select an option [1-2]: " gate_choice

    case "$gate_choice" in
        1)
            install_vps_stack
            local stack_rc=$?
            if [[ $stack_rc -eq 1 ]]; then
                echo ""
                echo -e "${C_YELLOW}QEMU setup failed on this host.${C_RESET}"
                echo ""
                read -rp "  Press Enter to continue..." _
                return 1
            elif [[ $stack_rc -eq 2 ]]; then
                : # Already handled — Docker VPS was created instead
            else
                vps_create
            fi
            ;;
        2) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_kvm_menu
}

_frosty_vps_launch() {
    local vm_name="$1"
    local img_key vm_ram vm_cpu ssh_port port_forwards
    img_key="$(_frosty_vps_meta_get "$vm_name" image)"
    vm_ram="$(_frosty_vps_meta_get "$vm_name" vm_ram)"
    vm_cpu="$(_frosty_vps_meta_get "$vm_name" vm_cpu)"
    ssh_port="$(_frosty_vps_meta_get "$vm_name" ssh_port)"
    port_forwards="$(_frosty_vps_meta_get "$vm_name" port_forwards)"

    local host_avail_mb
    host_avail_mb="$(free -m | awk '/^Mem:/{print $7}')"
    if [[ -n "$host_avail_mb" && -n "$vm_ram" && "$vm_ram" -ge "$host_avail_mb" ]]; then
        _frosty_fail "VM '$vm_name' is configured for ${vm_ram} MB RAM, which exceeds available host memory (${host_avail_mb} MB)."
        _frosty_warn "Use option [6] Edit VPS Config -> Change RAM to set a valid amount (e.g. 32768)."
        return 1
    fi

    local vm_disk_path="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    local seed_iso="${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso"

    local hostfwd="hostfwd=tcp::${ssh_port}-:22"
    if [[ -n "$port_forwards" ]]; then
        IFS=',' read -ra fwds <<< "$port_forwards"
        for fw in "${fwds[@]}"; do
            [[ -n "$fw" ]] && hostfwd="${hostfwd},hostfwd=tcp::${fw\%\%:*}-:${fw##*:}"
        done
    fi

    local accel_args=()
    if [[ "$(_frosty_vps_kvm_usable)" -eq 1 ]]; then
        accel_args=(-enable-kvm -cpu host)
    else
        accel_args=(-cpu max)
    fi

    load_module "pm2.sh"
    if ! _frosty_ensure_pm2_always; then
        _frosty_fail "pm2 unavailable — cannot start VM '${vm_name}'"
        return 1
    fi
    pm2 delete "$(_frosty_vps_pm2_name "$vm_name")" >/dev/null 2>&1

    _frosty_pm2_start "$(_frosty_vps_pm2_name "$vm_name")" "$FROSTY_VPS_IMG_DIR" \
        "qemu-system-x86_64" \
        "-name" "$vm_name" \
        "-m" "$vm_ram" \
        "-smp" "$vm_cpu" \
        "${accel_args[@]}" \
        "-drive" "file=${vm_disk_path},format=qcow2,if=virtio" \
        "-drive" "file=${seed_iso},format=raw,if=virtio" \
        "-netdev" "user,id=n0,${hostfwd}" \
        "-device" "virtio-net-pci,netdev=n0" \
        "-nographic" \
        "-serial" "null" \
        "-monitor" "none" \
        "-display" "none"
}

vps_create() {
    echo ""
    echo -e "${C_CYAN:-}== Create New VPS ==${C_RESET:-}"
    echo ""
    read -erp "  VM name (e.g. client1-vps): " vm_name
    vm_name="$(echo "$vm_name" | tr -cd 'A-Za-z0-9_-')"
    [[ -z "$vm_name" ]] && { _frosty_fail "Name required"; return 1; }

    if [[ -f "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" ]]; then
        _frosty_fail "A VM named '$vm_name' already exists"
        return 1
    fi

    echo "  Image: [1] Ubuntu 26.04 LTS (latest)  [2] Ubuntu 24.04 LTS  [3] Ubuntu 22.04 LTS"
    echo "         [4] Debian 11  [5] Debian 12  [6] Debian 13 (latest)"
    read -erp "  Choice [1-6]: " img_choice
    case "$img_choice" in
        1) img_key="ubuntu2604" ;;
        2) img_key="ubuntu2404" ;;
        3) img_key="ubuntu2204" ;;
        4) img_key="debian11" ;;
        5) img_key="debian12" ;;
        6) img_key="debian13" ;;
        *) _frosty_fail "Invalid image choice"; return 1 ;;
    esac
    local img_url
    img_url="$(_frosty_vps_image_url "$img_key")"

    echo "  Resource preset: [1] Small (1 vCPU/1GB/10GB)  [2] Medium (2 vCPU/2GB/20GB)"
    echo "                   [3] Large (4 vCPU/4GB/40GB)  [4] Custom"
    read -erp "  Choice [1-4]: " preset_choice
    case "$preset_choice" in
        1) vm_cpu=1; vm_ram=1024; vm_disk=10 ;;
        2) vm_cpu=2; vm_ram=2048; vm_disk=20 ;;
        3) vm_cpu=4; vm_ram=4096; vm_disk=40 ;;
        4)
            read -erp "  RAM in MB (e.g. 32768): " vm_ram
            read -erp "  vCPUs (e.g. 8): " vm_cpu
            read -erp "  Disk size in GB (number only, e.g. 30): " vm_disk
            ;;
        *) _frosty_fail "Invalid preset choice"; return 1 ;;
    esac

    vm_ram="${vm_ram//[[:space:]]/}"
    vm_cpu="${vm_cpu//[[:space:]]/}"
    vm_disk="${vm_disk//[[:space:]]/}"

    if [[ ! "$vm_ram" =~ ^[0-9]+$ || ! "$vm_cpu" =~ ^[0-9]+$ || ! "$vm_disk" =~ ^[0-9]+$ ]]; then
        _frosty_fail "RAM, vCPU, and disk size must be plain numbers (got RAM='${vm_ram}', vCPU='${vm_cpu}', Disk='${vm_disk}')"
        return 1
    fi

    local host_avail_mb
    host_avail_mb="$(free -m | awk '/^Mem:/{print $7}')"
    if [[ -n "$host_avail_mb" && "$vm_ram" -ge "$host_avail_mb" ]]; then
        _frosty_fail "Requested RAM (${vm_ram} MB) exceeds available host memory (${host_avail_mb} MB)"
        return 1
    fi

    local ssh_port=""
    local port_attempts=0
    while [[ -z "$ssh_port" && $port_attempts -lt 50 ]]; do
        local candidate=$(( (RANDOM % 40000) + 20000 ))
        if ! ss -ltn 2>/dev/null | grep -q ":${candidate} " && \
           [[ ! -f "${FROSTY_VPS_IMG_DIR}/.port_${candidate}" ]]; then
            ssh_port="$candidate"
        fi
        port_attempts=$((port_attempts + 1))
    done
    if [[ -z "$ssh_port" ]]; then
        _frosty_fail "Could not find a free port after 50 attempts"
        return 1
    fi
    touch "${FROSTY_VPS_IMG_DIR}/.port_${ssh_port}"

    read -rsp "  Set root password for the VM: " vm_pass
    echo ""
    if [[ -z "$vm_pass" ]]; then
        _frosty_fail "Root password is required"
        return 1
    fi

    local base_img="${FROSTY_VPS_IMG_DIR}/${img_key}.qcow2"
    local vm_disk_path="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    local seed_iso="${FROSTY_VPS_IMG_DIR}/${vm
