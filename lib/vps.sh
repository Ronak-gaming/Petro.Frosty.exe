#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# KVM VPS — rewritten to use QEMU directly instead of libvirt.
#
# Why: libvirt's "default" network needs a bridge (virbr0) + dnsmasq
# for DHCP + iptables NAT — a stack that repeatedly failed to hand out
# IPs in sandboxed/nested-virt hosts (Codespaces, some containers).
#
# This version uses QEMU's built-in user-mode networking (SLIRP) with
# hostfwd port mapping instead — a pure userspace network stack that
# needs NO host bridge, DHCP server, or NAT rules. Every VM is reached
# via localhost:<its assigned SSH port>, guaranteed to work anywhere
# QEMU itself runs. KVM acceleration is auto-detected per VM: if
# /dev/kvm is usable, VMs run at near-native speed (-enable-kvm -cpu
# host); if not, they fall back to plain software emulation (TCG) —
# slower, but still fully functional — instead of failing outright.
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

# Returns "1" if /dev/kvm exists AND is actually usable (readable +
# writable) right now, "0" otherwise. Checked fresh per VM start,
# since availability can change between attempts in some sandboxes.
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

    # A dpkg left interrupted by an earlier kill/restart (common in this
    # project's non-systemd environment) blocks EVERY apt operation
    # until repaired — fix it first rather than letting installs fail.
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
        read -rp "  Choice [1-2]: " kvm_fallback_choice

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
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
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

    # Keep the /dev/kvm permission fix persistent via udev, same as
    # before — harmless if KVM isn't present at all.
    if [[ ! -f /etc/udev/rules.d/99-frosty-kvm.rules ]]; then
        echo 'KERNEL=="kvm", MODE="0666"' > /etc/udev/rules.d/99-frosty-kvm.rules
        udevadm control --reload-rules >/dev/null 2>&1
        udevadm trigger >/dev/null 2>&1
    fi
    _frosty_vps_fix_kvm_perms

    load_module "pm2.sh"
    if ! _frosty_ensure_pm2; then
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

# Every VM is always reached via 127.0.0.1 on its own assigned port —
# there's no guest IP to track anymore since networking is host-side
# port mapping, not a real network interface.
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
    clear
    print_banner

    if vps_kvm_exists_any; then
        show_vps_kvm_full_menu
        return 0
    fi

    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}            ${C_ICE}${C_BOLD}❄  K V M   V P S  ❄${C_RESET}                ${C_FROST}${C_BOLD}║${C_RESET}"
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

# Builds the full QEMU command as an array and starts it under pm2.
# Reads everything it needs from the VM's .meta file, so restarting a
# VM later (after an edit, or after a host reboot) reproduces the
# exact same launch config without asking anything again.
_frosty_vps_launch() {
    local vm_name="$1"
    local img_key vm_ram vm_cpu ssh_port port_forwards
    img_key="$(_frosty_vps_meta_get "$vm_name" image)"
    vm_ram="$(_frosty_vps_meta_get "$vm_name" vm_ram)"
    vm_cpu="$(_frosty_vps_meta_get "$vm_name" vm_cpu)"
    ssh_port="$(_frosty_vps_meta_get "$vm_name" ssh_port)"
    port_forwards="$(_frosty_vps_meta_get "$vm_name" port_forwards)"

    local vm_disk_path="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    local seed_iso="${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso"

    local hostfwd="hostfwd=tcp::${ssh_port}-:22"
    if [[ -n "$port_forwards" ]]; then
        IFS=',' read -ra fwds <<< "$port_forwards"
        for fw in "${fwds[@]}"; do
            [[ -n "$fw" ]] && hostfwd="${hostfwd},hostfwd=tcp::${fw%%:*}-:${fw##*:}"
        done
    fi

    local accel_args=()
    if [[ "$(_frosty_vps_kvm_usable)" -eq 1 ]]; then
        accel_args=(-enable-kvm -cpu host)
    else
        accel_args=(-cpu qemu64)
    fi

    load_module "pm2.sh"
    if ! _frosty_ensure_pm2; then
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
    read -rp "  VM name (e.g. client1-vps): " vm_name
    [[ -z "$vm_name" ]] && { _frosty_fail "Name required"; return 1; }

    if [[ -f "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" ]]; then
        _frosty_fail "A VM named '$vm_name' already exists"
        return 1
    fi

    echo "  Image: [1] Ubuntu 26.04 LTS (latest)  [2] Ubuntu 24.04 LTS  [3] Ubuntu 22.04 LTS"
    echo "         [4] Debian 11  [5] Debian 12  [6] Debian 13 (latest)"
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
    local img_url
    img_url="$(_frosty_vps_image_url "$img_key")"

    echo "  Resource preset: [1] Small (1 vCPU/1GB/10GB)  [2] Medium (2 vCPU/2GB/20GB)"
    echo "                   [3] Large (4 vCPU/4GB/40GB)  [4] Custom"
    read -rp "  Choice [1-4]: " preset_choice
    case "$preset_choice" in
        1) vm_cpu=1; vm_ram=1024; vm_disk=10 ;;
        2) vm_cpu=2; vm_ram=2048; vm_disk=20 ;;
        3) vm_cpu=4; vm_ram=4096; vm_disk=40 ;;
        4)
            read -rp "  RAM in MB: " vm_ram
            read -rp "  vCPUs: " vm_cpu
            read -rp "  Disk size in GB (number only, e.g. 20): " vm_disk
            ;;
        *) _frosty_fail "Invalid preset choice"; return 1 ;;
    esac

    vm_ram="$(echo "$vm_ram" | tr -cd '0-9')"
    vm_cpu="$(echo "$vm_cpu" | tr -cd '0-9')"
    vm_disk="$(echo "$vm_disk" | tr -cd '0-9')"

    if [[ -z "$vm_ram" || -z "$vm_cpu" || -z "$vm_disk" ]]; then
        _frosty_fail "RAM, vCPU, and disk size must be numbers"
        return 1
    fi

    local ssh_port=2200
    while ss -ltn 2>/dev/null | grep -q ":${ssh_port} " || [[ -f "${FROSTY_VPS_IMG_DIR}/.port_${ssh_port}" ]]; do
        ssh_port=$((ssh_port + 1))
    done
    touch "${FROSTY_VPS_IMG_DIR}/.port_${ssh_port}"

    read -rsp "  Set root password for the VM: " vm_pass
    echo ""
    if [[ -z "$vm_pass" ]]; then
        _frosty_fail "Root password is required"
        return 1
    fi

    local base_img="${FROSTY_VPS_IMG_DIR}/${img_key}.qcow2"
    local vm_disk_path="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    local seed_iso="${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso"

    if [[ ! -f "$base_img" ]]; then
        echo "    Downloading ${img_key} cloud image (this may take a few minutes)..."
        if ! timeout 900 curl -fL -o "$base_img" "$img_url" >/tmp/frosty_vps_download.log 2>&1; then
            _frosty_fail "Image download failed or timed out — see /tmp/frosty_vps_download.log"
            rm -f "$base_img"
            return 1
        fi
        _frosty_ok "Base image downloaded"
    fi

    qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$vm_disk_path" "${vm_disk}G" >/tmp/frosty_vps_disk.log 2>&1
    if [[ $? -ne 0 ]]; then
        _frosty_fail "Disk creation failed — see /tmp/frosty_vps_disk.log"
        return 1
    fi

    local cloud_dir="${FROSTY_VPS_IMG_DIR}/${vm_name}-cloudinit"
    mkdir -p "$cloud_dir"
    local pubkey
    pubkey="$(cat "${FROSTY_VPS_DIR}/frosty_vps_key.pub" 2>/dev/null)"

    cat > "${cloud_dir}/user-data" << CIEOF
#cloud-config
hostname: ${vm_name}
users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: true
chpasswd:
  list: |
    root:${vm_pass}
  expire: false
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
CIEOF
    cat > "${cloud_dir}/meta-data" << CIEOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
CIEOF

    genisoimage -output "$seed_iso" -volid cidata -joliet -rock "${cloud_dir}/user-data" "${cloud_dir}/meta-data" >/tmp/frosty_vps_iso.log 2>&1

    cat > "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" << METAEOF
image=${img_key}
vm_ram=${vm_ram}
vm_cpu=${vm_cpu}
vm_disk=${vm_disk}
ssh_port=${ssh_port}
port_forwards=
created=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    echo "    Starting VM under pm2..."
    if ! _frosty_vps_launch "$vm_name"; then
        _frosty_fail "Failed to start VM — check: pm2 logs $(_frosty_vps_pm2_name "$vm_name")"
        return 1
    fi
    _frosty_ok "VM '${vm_name}' created and starting (SSH will be on 127.0.0.1:${ssh_port})"

    echo "    Waiting for SSH to come up inside the VM (up to 90s — first boot is slower)..."
    local ssh_ready=0
    for i in $(seq 1 30); do
        if ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -p "$ssh_port" -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "root@127.0.0.1" "echo ok" >/dev/null 2>&1; then
            ssh_ready=1
            break
        fi
        sleep 3
    done

    if [[ "$ssh_ready" -eq 0 ]]; then
        _frosty_warn "SSH not reachable yet after 90s — it may still be booting. Check: pm2 logs $(_frosty_vps_pm2_name "$vm_name")"
        _frosty_warn "Retry manually later with: ssh -i ${FROSTY_VPS_DIR}/frosty_vps_key -p ${ssh_port} root@127.0.0.1"
    else
        _frosty_ok "SSH reachable"
        echo "    Running post-boot setup (update, upgrade, fetch tool)..."
        ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -p "$ssh_port" -o StrictHostKeyChecking=no -o BatchMode=yes "root@127.0.0.1" '
            export DEBIAN_FRONTEND=noninteractive
            apt update -y
            apt upgrade -y
            if apt-cache show neofetch >/dev/null 2>&1; then
                apt install -y neofetch
            elif apt-cache show screenfetch >/dev/null 2>&1; then
                apt install -y screenfetch
            fi
        ' >/tmp/frosty_vps_postsetup_${vm_name}.log 2>&1

        if [[ $? -eq 0 ]]; then
            _frosty_ok "Post-boot setup complete"
        else
            _frosty_warn "Post-boot setup had issues — see /tmp/frosty_vps_postsetup_${vm_name}.log"
        fi
    fi

    local display_ip="${FROSTY_PUBLIC_IP:-}"
    if [[ -z "$display_ip" ]]; then
        display_ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
    fi
    [[ -z "$display_ip" ]] && display_ip="127.0.0.1"

    echo ""
    echo -e "    ${C_CYAN:-}Connect with:${C_RESET:-}"
    echo "      ssh -i ${FROSTY_VPS_DIR}/frosty_vps_key -p ${ssh_port} root@${display_ip}"
    echo ""
    echo "  Share this VM now? [1] tmate  [2] sshx  [3] Live Terminal (local)  [4] Skip"
    read -rp "  Choice [1-4]: " share_now
    case "$share_now" in
        1) vps_share_tmate <<< "$vm_name" ;;
        2) vps_share_sshx <<< "$vm_name" ;;
        3) vps_live_terminal <<< "$vm_name" ;;
        *) : ;;
    esac

    return 0
}

vps_list() {
    echo ""
    echo "== VPS Instances =="
    _frosty_vps_check_stack || return 1
    load_module "pm2.sh"
    if command -v pm2 >/dev/null 2>&1; then
        # Show pm2's full table rather than grep-filtering it — a filter
        # that only kept "frosty-vps-" and border lines also silently
        # dropped the header row (it contains neither), leaving a table
        # with no column labels.
        pm2 list 2>/dev/null
    else
        ls "${FROSTY_VPS_IMG_DIR}"/*.meta 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.meta$//' || echo "  No VMs found."
    fi
}

vps_dashboard() {
    echo ""
    echo -e "${C_CYAN:-}== VPS Resource Dashboard ==${C_RESET:-}"
    _frosty_vps_check_stack || return 1

    local metas
    metas="$(ls "${FROSTY_VPS_IMG_DIR}"/*.meta 2>/dev/null)"
    if [[ -z "$metas" ]]; then
        echo "  No VMs found."
        return 0
    fi

    printf "  %-20s %-10s %-8s %-8s %-8s %-8s\n" "NAME" "STATE" "vCPUs" "RAM(MB)" "DISK(GB)" "PORT"
    printf "  %-20s %-10s %-8s %-8s %-8s %-8s\n" "----" "-----" "-----" "-------" "--------" "----"

    for meta in $metas; do
        local vm
        vm="$(basename "$meta" .meta)"
        local state="stopped"
        if pm2 describe "$(_frosty_vps_pm2_name "$vm")" 2>/dev/null | grep -q "online"; then
            state="running"
        fi
        printf "  %-20s %-10s %-8s %-8s %-8s %-8s\n" \
            "$vm" "$state" \
            "$(_frosty_vps_meta_get "$vm" vm_cpu)" \
            "$(_frosty_vps_meta_get "$vm" vm_ram)" \
            "$(_frosty_vps_meta_get "$vm" vm_disk)" \
            "$(_frosty_vps_meta_get "$vm" ssh_port)"
    done
    echo ""
}

vps_start() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to start: " vm_name
    if [[ ! -f "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi
    if _frosty_vps_launch "$vm_name"; then
        _frosty_ok "'$vm_name' started"
    else
        _frosty_fail "Start failed — check: pm2 logs $(_frosty_vps_pm2_name "$vm_name")"
        return 1
    fi
}

vps_stop() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to stop: " vm_name
    load_module "pm2.sh"
    if pm2 stop "$(_frosty_vps_pm2_name "$vm_name")" >/dev/null 2>&1; then
        _frosty_ok "'$vm_name' stop signal sent"
        _frosty_warn "Note: this is a hard stop (SIGTERM to QEMU), not a graceful OS shutdown — same as unplugging power"
    else
        _frosty_fail "Stop failed — VM may not be running"
        return 1
    fi
}

vps_edit_config() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to edit: " vm_name
    if [[ ! -f "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi

    echo "  [1] Change RAM  [2] Change vCPUs"
    echo -e "  ${C_YELLOW:-}Note: changes require a restart to take effect (no live-resize without libvirt)${C_RESET:-}"
    read -rp "  Choice: " edit_choice
    local meta="${FROSTY_VPS_IMG_DIR}/${vm_name}.meta"
    case "$edit_choice" in
        1)
            read -rp "  New RAM in MB: " new_ram
            new_ram="$(echo "$new_ram" | tr -cd '0-9')"
            sed -i "s/^vm_ram=.*/vm_ram=${new_ram}/" "$meta"
            load_module "pm2.sh"
            pm2 delete "$(_frosty_vps_pm2_name "$vm_name")" >/dev/null 2>&1
            _frosty_vps_launch "$vm_name"
            _frosty_ok "RAM updated to ${new_ram}MB, VM restarted"
            ;;
        2)
            read -rp "  New vCPU count: " new_cpu
            new_cpu="$(echo "$new_cpu" | tr -cd '0-9')"
            sed -i "s/^vm_cpu=.*/vm_cpu=${new_cpu}/" "$meta"
            load_module "pm2.sh"
            pm2 delete "$(_frosty_vps_pm2_name "$vm_name")" >/dev/null 2>&1
            _frosty_vps_launch "$vm_name"
            _frosty_ok "vCPUs updated to ${new_cpu}, VM restarted"
            ;;
        *) _frosty_fail "Invalid choice" ;;
    esac
}

vps_delete() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to DELETE: " vm_name
    read -rp "  Type DELETE to confirm removing '$vm_name' and its disk: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        echo "Cancelled."
        return 1
    fi
    load_module "pm2.sh"
    pm2 delete "$(_frosty_vps_pm2_name "$vm_name")" >/dev/null 2>&1
    local ssh_port
    ssh_port="$(_frosty_vps_sshport "$vm_name")"
    [[ -n "$ssh_port" ]] && rm -f "${FROSTY_VPS_IMG_DIR}/.port_${ssh_port}"
    rm -rf "${FROSTY_VPS_IMG_DIR}/${vm_name}-cloudinit" "${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso" \
        "${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2" "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta"
    rm -rf "${FROSTY_VPS_SNAP_DIR}/${vm_name}"
    _frosty_ok "'$vm_name' deleted"
}

# Internal qcow2 snapshots via qemu-img — the VM must be stopped first
# since these aren't live/QMP-based snapshots, just offline disk state.
vps_snapshot_create() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to snapshot: " vm_name
    local disk="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    if [[ ! -f "$disk" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi
    if pm2 describe "$(_frosty_vps_pm2_name "$vm_name")" 2>/dev/null | grep -q "online"; then
        _frosty_fail "Stop the VM first — snapshots require it to be offline"
        return 1
    fi
    read -rp "  Snapshot name (e.g. before-update): " snap_name
    [[ -z "$snap_name" ]] && snap_name="snap-$(date +%Y%m%d-%H%M%S)"

    if qemu-img snapshot -c "$snap_name" "$disk" >/tmp/frosty_vps_snap.log 2>&1; then
        _frosty_ok "Snapshot '$snap_name' created for '$vm_name'"
    else
        _frosty_fail "Snapshot creation failed — see /tmp/frosty_vps_snap.log"
        return 1
    fi
}

vps_snapshot_list() {
    echo ""
    read -rp "  VM name: " vm_name
    echo "== Snapshots for $vm_name =="
    qemu-img snapshot -l "${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2" 2>&1
}

vps_snapshot_restore() {
    echo ""
    read -rp "  VM name: " vm_name
    local disk="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    qemu-img snapshot -l "$disk" 2>/dev/null
    echo ""
    if pm2 describe "$(_frosty_vps_pm2_name "$vm_name")" 2>/dev/null | grep -q "online"; then
        _frosty_fail "Stop the VM first — restoring requires it to be offline"
        return 1
    fi
    read -rp "  Snapshot name to restore: " snap_name
    read -rp "  Type RESTORE to confirm reverting '$vm_name' to '$snap_name': " confirm
    if [[ "$confirm" != "RESTORE" ]]; then
        echo "Cancelled."
        return 1
    fi
    if qemu-img snapshot -a "$snap_name" "$disk" >/tmp/frosty_vps_restore.log 2>&1; then
        _frosty_ok "'$vm_name' reverted to snapshot '$snap_name'"
    else
        _frosty_fail "Restore failed — see /tmp/frosty_vps_restore.log"
        return 1
    fi
}

vps_snapshot_delete() {
    echo ""
    read -rp "  VM name: " vm_name
    local disk="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    qemu-img snapshot -l "$disk" 2>/dev/null
    echo ""
    read -rp "  Snapshot name to delete: " snap_name
    if qemu-img snapshot -d "$snap_name" "$disk" >/tmp/frosty_vps_snapdel.log 2>&1; then
        _frosty_ok "Snapshot '$snap_name' deleted"
    else
        _frosty_fail "Delete failed — see /tmp/frosty_vps_snapdel.log"
        return 1
    fi
}

show_vps_snapshot_submenu() {
    clear
    print_banner
    echo -e "${C_CYAN}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║          ❄  S N A P S H O T S  ❄              ║${C_RESET}"
    echo -e "${C_CYAN}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_CYAN}║  [1] Create Snapshot (VM must be stopped)     ║${C_RESET}"
    echo -e "${C_CYAN}║  [2] List Snapshots                           ║${C_RESET}"
    echo -e "${C_CYAN}║  [3] Restore Snapshot (VM must be stopped)    ║${C_RESET}"
    echo -e "${C_CYAN}║  [4] Delete Snapshot                          ║${C_RESET}"
    echo -e "${C_CYAN}║  [5] Back                                     ║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-5]: " snap_choice
    case "$snap_choice" in
        1) vps_snapshot_create ;;
        2) vps_snapshot_list ;;
        3) vps_snapshot_restore ;;
        4) vps_snapshot_delete ;;
        5) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_snapshot_submenu
}

# Port forwards are QEMU hostfwd rules baked in at launch time — unlike
# the old iptables-based approach, there's no live "add a rule" without
# restarting the VM's QEMU process (SLIRP forwards are fixed at start).
vps_firewall_add() {
    echo ""
    read -rp "  VM name: " vm_name
    local meta="${FROSTY_VPS_IMG_DIR}/${vm_name}.meta"
    if [[ ! -f "$meta" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi

    read -rp "  Host port to forward (e.g. 25565): " new_port
    read -rp "  Guest port (usually same, e.g. 25565): " guest_port
    guest_port="${guest_port:-$new_port}"

    local existing
    existing="$(_frosty_vps_meta_get "$vm_name" port_forwards)"
    local updated="${existing:+${existing},}${new_port}:${guest_port}"
    sed -i "s/^port_forwards=.*/port_forwards=${updated}/" "$meta"

    _frosty_ok "Port ${new_port} -> guest:${guest_port} added"
    _frosty_warn "This takes effect on the VM's NEXT restart (Stop, then Start) — SLIRP forwards are fixed at launch"
}

vps_firewall_list() {
    echo ""
    read -rp "  VM name: " vm_name
    echo "== Forwarded Ports for $vm_name =="
    echo "  SSH: $(_frosty_vps_sshport "$vm_name") -> guest:22"
    local forwards
    forwards="$(_frosty_vps_meta_get "$vm_name" port_forwards)"
    if [[ -n "$forwards" ]]; then
        IFS=',' read -ra fwds <<< "$forwards"
        for fw in "${fwds[@]}"; do
            echo "  ${fw%%:*} -> guest:${fw##*:}"
        done
    fi
}

show_vps_firewall_submenu() {
    clear
    print_banner
    echo -e "${C_CYAN}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_CYAN}║       ❄  F I R E W A L L / P O R T S  ❄       ║${C_RESET}"
    echo -e "${C_CYAN}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_CYAN}║  [1] Add Port Forward                         ║${C_RESET}"
    echo -e "${C_CYAN}║  [2] List Forwarded Ports                     ║${C_RESET}"
    echo -e "${C_CYAN}║  [3] Back                                     ║${C_RESET}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-3]: " fw_choice
    case "$fw_choice" in
        1) vps_firewall_add ;;
        2) vps_firewall_list ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_firewall_submenu
}

# Direct SSH into the VM via its hostfwd port — always 127.0.0.1, since
# there's no separate guest IP in user-mode networking.
vps_live_terminal() {
    echo ""
    echo -e "${C_CYAN:-}== Live Terminal (Local) ==${C_RESET:-}"
    read -rp "  VM name to open: " vm_name

    local ssh_port
    ssh_port="$(_frosty_vps_sshport "$vm_name")"
    if [[ -z "$ssh_port" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi

    if ! pm2 describe "$(_frosty_vps_pm2_name "$vm_name")" 2>/dev/null | grep -q "online"; then
        _frosty_warn "'$vm_name' is not running — starting it first..."
        _frosty_vps_launch "$vm_name"
        sleep 5
    fi

    echo "    Checking SSH is reachable..."
    if ! ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -p "$ssh_port" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "root@127.0.0.1" "echo ok" >/dev/null 2>&1; then
        _frosty_fail "Could not reach '$vm_name' on port ${ssh_port} — it may still be booting"
        _frosty_warn "Try again in a few seconds, or check: pm2 logs $(_frosty_vps_pm2_name "$vm_name")"
        return 1
    fi

    echo -e "    ${C_YELLOW:-}Opening a live terminal into '$vm_name'. Type 'exit' to return.${C_RESET:-}"
    echo ""
    ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -p "$ssh_port" -o StrictHostKeyChecking=no -t "root@127.0.0.1" "command -v neofetch >/dev/null 2>&1 && neofetch || (command -v screenfetch >/dev/null 2>&1 && screenfetch); exec bash -l"
    echo ""
    _frosty_ok "Returned from live terminal into '$vm_name'"
}

vps_share_tmate() {
    echo ""
    echo "== Share Terminal via tmate =="
    read -rp "  VM name to access: " vm_name

    local ssh_port
    ssh_port="$(_frosty_vps_sshport "$vm_name")"
    if [[ -z "$ssh_port" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
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

    echo "    Checking connectivity to tmate's relay server..."
    if ! timeout 6 bash -c "cat < /dev/null > /dev/tcp/tmate.io/22" 2>/dev/null; then
        _frosty_fail "Cannot reach tmate.io on port 22 from this host"
        _frosty_warn "This network likely blocks outbound port 22. Try sshx instead — it works over port 443."
        return 1
    fi
    _frosty_ok "tmate.io is reachable"

    local tmate_sock="/tmp/frosty-tmate-${vm_name}.sock"
    local ssh_line=""
    ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"

    if [[ -n "$ssh_line" ]]; then
        _frosty_ok "Existing tmate session for '$vm_name' is still alive — reusing it"
    else
        [[ -S "$tmate_sock" ]] && tmate -S "$tmate_sock" kill-server >/dev/null 2>&1
        rm -f "$tmate_sock"
        echo -e "    ${C_CYAN:-}Starting a new tmate session into VM '$vm_name'...${C_RESET:-}"
        tmate -S "$tmate_sock" -f /dev/null new-session -d -n frosty-vps \
            "ssh -i ${FROSTY_VPS_DIR}/frosty_vps_key -p ${ssh_port} -o StrictHostKeyChecking=no -t root@127.0.0.1 'command -v neofetch >/dev/null 2>&1 && neofetch || screenfetch; exec bash -l'" \
            2>/tmp/frosty_tmate_session.log

        echo -n "    Waiting for tmate to establish the session"
        local waited=0
        while [[ ${waited} -lt 20 ]]; do
            ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"
            [[ -n "$ssh_line" ]] && break
            echo -n "."
            sleep 1
            waited=$((waited + 1))
        done
        echo ""

        if [[ -z "$ssh_line" ]]; then
            _frosty_fail "tmate session did not come up after ${waited}s — see /tmp/frosty_tmate_session.log"
            return 1
        fi
    fi

    echo ""
    echo -e "    ${C_YELLOW:-}Anyone with the link/command below gets a live terminal into '$vm_name':${C_RESET:-}"
    tmate -S "$tmate_sock" display -p '#{tmate_ssh}'
    tmate -S "$tmate_sock" display -p '#{tmate_web}'
}

vps_rejoin_tmate() {
    echo ""
    echo "== Rejoin Existing tmate Session =="
    read -rp "  VM name: " vm_name
    local tmate_sock="/tmp/frosty-tmate-${vm_name}.sock"
    local ssh_line=""

    [[ -S "$tmate_sock" ]] && ssh_line="$(tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null)"

    if [[ -z "$ssh_line" ]]; then
        _frosty_warn "No live tmate session found for '$vm_name' — starting a new one instead"
        [[ -S "$tmate_sock" ]] && tmate -S "$tmate_sock" kill-server >/dev/null 2>&1
        rm -f "$tmate_sock"
        vps_share_tmate <<< "$vm_name"
        return 0
    fi

    echo -e "    ${C_CYAN:-}Session is alive. Sharing details for '$vm_name':${C_RESET:-}"
    echo "$ssh_line"
    tmate -S "$tmate_sock" display -p '#{tmate_web}' 2>/dev/null
}

vps_share_sshx() {
    echo ""
    echo "== Share Terminal via sshx =="
    read -rp "  VM name to access: " vm_name

    local ssh_port
    ssh_port="$(_frosty_vps_sshport "$vm_name")"
    if [[ -z "$ssh_port" ]]; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi

    local sshx_log="/tmp/frosty-sshx-${vm_name}.log"
    local sshx_pidfile="/tmp/frosty-sshx-${vm_name}.pid"

    if [[ -f "$sshx_pidfile" ]] && kill -0 "$(cat "$sshx_pidfile" 2>/dev/null)" 2>/dev/null; then
        _frosty_ok "Existing sshx session for '$vm_name' is still alive"
    else
        echo "    Checking connectivity to sshx.io..."
        if ! timeout 6 bash -c "cat < /dev/null > /dev/tcp/sshx.io/443" 2>/dev/null; then
            _frosty_fail "Cannot reach sshx.io from this host"
            return 1
        fi
        echo -e "    ${C_CYAN:-}Starting a new sshx session into VM '$vm_name'...${C_RESET:-}"
        rm -f "$sshx_log"
        (
            ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -p "$ssh_port" -o StrictHostKeyChecking=no -tt "root@127.0.0.1" "command -v sshx >/dev/null 2>&1 || curl -sSf https://sshx.io/get | sh; (command -v neofetch >/dev/null 2>&1 && neofetch || screenfetch) ; sshx" > "$sshx_log" 2>&1
        ) &
        echo $! > "$sshx_pidfile"

        echo -n "    Waiting for sshx link"
        local waited=0 link=""
        while [[ ${waited} -lt 20 ]]; do
            link="$(sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$sshx_log" 2>/dev/null | grep -oE 'https://sshx\.io/s/[A-Za-z0-9#]+' | tail -1)"
            [[ -n "$link" ]] && break
            echo -n "."
            sleep 1
            waited=$((waited + 1))
        done
        echo ""
    fi

    local link
    link="$(sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$sshx_log" 2>/dev/null | grep -oE 'https://sshx\.io/s/[A-Za-z0-9#]+' | tail -1)"
    if [[ -n "$link" ]]; then
        echo -e "    ${C_YELLOW:-}Share this link for a live browser terminal into '$vm_name':${C_RESET:-}"
        echo "    $link"
    else
        _frosty_warn "sshx link not detected yet — check $sshx_log manually"
    fi
}

vps_rejoin_sshx() {
    echo ""
    echo "== Rejoin Existing sshx Session =="
    read -rp "  VM name: " vm_name
    local sshx_log="/tmp/frosty-sshx-${vm_name}.log"
    local sshx_pidfile="/tmp/frosty-sshx-${vm_name}.pid"

    if [[ ! -f "$sshx_pidfile" ]] || ! kill -0 "$(cat "$sshx_pidfile" 2>/dev/null)" 2>/dev/null; then
        _frosty_warn "No active sshx session found for '$vm_name' — starting a new one instead"
        vps_share_sshx <<< "$vm_name"
        return 0
    fi

    local link
    link="$(sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$sshx_log" | grep -oE 'https://sshx\.io/s/[A-Za-z0-9#]+' | tail -1)"
    if [[ -n "$link" ]]; then
        echo -e "    ${C_CYAN:-}Session is alive. Link for '$vm_name':${C_RESET:-}"
        echo "    $link"
    else
        _frosty_warn "Session process alive but no link found in log — check $sshx_log manually"
    fi
}

show_vps_kvm_full_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}        ${C_ICE}${C_BOLD}❄  V P S   I N S T A L L E R  ❄${C_RESET}        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET}  ${C_WHITE}Set Up VPS${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[2]${C_RESET}  ${C_WHITE}List VPS${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[3]${C_RESET}  ${C_WHITE}Resource Dashboard${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[4]${C_RESET}  ${C_WHITE}Start VPS${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_YELLOW}[5]${C_RESET}  ${C_WHITE}Stop VPS${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[6]${C_RESET}  ${C_WHITE}Edit VPS Config${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[7]${C_RESET}  ${C_WHITE}Snapshots${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[8]${C_RESET}  ${C_WHITE}Firewall / Ports${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[9]${C_RESET}  ${C_WHITE}Delete VPS${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[10]${C_RESET} ${C_WHITE}Share via tmate${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[11]${C_RESET} ${C_WHITE}Rejoin tmate Session${C_RESET}                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[12]${C_RESET} ${C_WHITE}Share via sshx${C_RESET}                          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[13]${C_RESET} ${C_WHITE}Rejoin sshx Session${C_RESET}                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[14]${C_RESET} ${C_WHITE}Live Terminal (Local)${C_RESET}                   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[15]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-15]: " vps_choice

    case "$vps_choice" in
        1) vps_create ;;
        2) vps_list ;;
        3) vps_dashboard ;;
        4) vps_start ;;
        5) vps_stop ;;
        6) vps_edit_config ;;
        7) show_vps_snapshot_submenu ;;
        8) show_vps_firewall_submenu ;;
        9) vps_delete ;;
        10) vps_share_tmate ;;
        11) vps_rejoin_tmate ;;
        12) vps_share_sshx ;;
        13) vps_rejoin_sshx ;;
        14) vps_live_terminal ;;
        15) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_kvm_full_menu
}
