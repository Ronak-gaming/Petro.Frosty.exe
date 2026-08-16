#!/usr/bin/env bash
set -uo pipefail

FROSTY_VPS_DIR="/var/lib/frosty-vps"
FROSTY_VPS_IMG_DIR="${FROSTY_VPS_DIR}/images"
FROSTY_VPS_SNAP_DIR="${FROSTY_VPS_DIR}/snapshots"

_frosty_vps_check_stack() {
    if ! command -v virsh >/dev/null 2>&1; then
        _frosty_warn "KVM/libvirt not installed yet — run Create VPS first"
        return 1
    fi
    return 0
}

install_vps_stack() {
    echo ""
    echo "== Installing KVM/Libvirt Stack =="

    if [[ ! -e /dev/kvm ]]; then
        _frosty_fail "/dev/kvm not found — nested virtualization not available here"
        return 1
    fi
    _frosty_ok "/dev/kvm present"

    local pkgs=(qemu-kvm libvirt-daemon-system libvirt-clients virtinst cloud-image-utils genisoimage bridge-utils iptables)
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "    Installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_vps_apt.log 2>&1
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >>/tmp/frosty_vps_apt.log 2>&1; then
            _frosty_ok "Libvirt/QEMU stack installed"
        else
            _frosty_fail "Install failed — see /tmp/frosty_vps_apt.log"
            return 1
        fi
    else
        _frosty_ok "Libvirt/QEMU stack already installed"
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable --now virtlogd >/dev/null 2>&1
        systemctl enable --now libvirtd >/dev/null 2>&1
    else
        if [[ ! -S /run/libvirt/virtlogd-sock ]]; then
            mkdir -p /run/libvirt
            virtlogd -d >/tmp/frosty_virtlogd.log 2>&1 &
            sleep 2
        fi
        service libvirtd start >/dev/null 2>&1 || (libvirtd -d >/tmp/frosty_libvirtd.log 2>&1 &)
        sleep 2
    fi

    if virsh list >/dev/null 2>&1; then
        _frosty_ok "libvirtd responding"
    else
        _frosty_fail "libvirtd not responding"
        return 1
    fi

    if ! virsh net-info default >/dev/null 2>&1; then
        virsh net-define /usr/share/libvirt/networks/default.xml >/dev/null 2>&1
    fi
    if ! virsh net-list --name 2>/dev/null | grep -q "^default$"; then
        virsh net-start default >/dev/null 2>&1
    fi
    virsh net-autostart default >/dev/null 2>&1
    if virsh net-list --name 2>/dev/null | grep -q "^default$"; then
        _frosty_ok "libvirt default network active"
    else
        _frosty_fail "Could not activate libvirt default network"
        return 1
    fi

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

_frosty_vps_ip() {
    grep '^vm_ip=' "${FROSTY_VPS_IMG_DIR}/$1.meta" 2>/dev/null | cut -d= -f2
}

vps_kvm_exists_any() {
    command -v virsh >/dev/null 2>&1 && virsh list --all --name 2>/dev/null | grep -q .
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
            if ! install_vps_stack; then
                echo ""
                echo -e "${C_YELLOW}No KVM detected on this host — switch to Docker VPS instead.${C_RESET}"
                echo ""
                read -rp "  Press Enter to continue..." _
                return 1
            fi
            vps_create
            ;;
        2) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_kvm_menu
}

vps_create() {
    echo ""
    echo -e "${C_CYAN:-}== Create New VPS ==${C_RESET:-}"
    echo ""
    read -rp "  VM name (e.g. client1-vps): " vm_name
    [[ -z "$vm_name" ]] && { _frosty_fail "Name required"; return 1; }

    if virsh dominfo "$vm_name" >/dev/null 2>&1; then
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

    read -rp "  SSH port to forward on host (e.g. 2201): " vm_sshport
    vm_sshport="$(echo "$vm_sshport" | tr -cd '0-9')"
    if [[ -z "$vm_sshport" ]]; then
        _frosty_fail "SSH port is required"
        return 1
    fi

    read -rp "  Set root password for the VM: " vm_pass
    if [[ -z "$vm_pass" ]]; then
        _frosty_fail "Root password is required"
        return 1
    fi

    local base_img="${FROSTY_VPS_IMG_DIR}/${img_key}.qcow2"
    local vm_disk_path="${FROSTY_VPS_IMG_DIR}/${vm_name}.qcow2"
    local seed_iso="${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso"

    if [[ ! -f "$base_img" ]]; then
        echo "    Downloading ${img_key} cloud image (this may take a few minutes)..."
        if ! curl -L -o "$base_img" "$img_url" >/tmp/frosty_vps_download.log 2>&1; then
            _frosty_fail "Image download failed — see /tmp/frosty_vps_download.log"
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

    echo "    Creating VM..."
    if virt-install \
        --name "$vm_name" \
        --memory "$vm_ram" \
        --vcpus "$vm_cpu" \
        --disk path="$vm_disk_path",format=qcow2 \
        --disk path="$seed_iso",device=cdrom \
        --os-variant generic \
        --network network=default,model=virtio \
        --graphics none \
        --import \
        --noautoconsole >/tmp/frosty_vps_create.log 2>&1; then
        _frosty_ok "VM '${vm_name}' created and starting"
    else
        _frosty_fail "VM creation failed — see /tmp/frosty_vps_create.log"
        return 1
    fi

    echo "    Waiting for VM to get an IP address (up to 60s)..."
    local vm_ip=""
    for i in $(seq 1 20); do
        vm_ip="$(virsh domifaddr "$vm_name" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1)"
        [[ -n "$vm_ip" ]] && break
        sleep 3
    done

    if [[ -z "$vm_ip" ]]; then
        _frosty_fail "Could not determine VM IP after 60s — check 'virsh domifaddr ${vm_name}' manually"
        return 1
    fi
    _frosty_ok "VM IP: ${vm_ip}"

    iptables -t nat -A PREROUTING -p tcp --dport "${vm_sshport}" -j DNAT --to-destination "${vm_ip}:22" -m comment --comment "frosty-${vm_name}-ssh"
    iptables -A FORWARD -p tcp -d "${vm_ip}" --dport 22 -j ACCEPT -m comment --comment "frosty-${vm_name}-ssh"

    cat > "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta" << METAEOF
image=${img_key}
ssh_port=${vm_sshport}
vm_ip=${vm_ip}
created=$(date '+%Y-%m-%d %H:%M:%S')
METAEOF

    echo ""
    echo "    Waiting for SSH to come up inside the VM (up to 60s)..."
    local ssh_ready=0
    for i in $(seq 1 20); do
        if ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes "root@${vm_ip}" "echo ok" >/dev/null 2>&1; then
            ssh_ready=1
            break
        fi
        sleep 3
    done

    if [[ "$ssh_ready" -eq 0 ]]; then
        _frosty_warn "SSH not reachable yet after 60s — skipping auto post-setup, run it manually once it is up"
    else
        _frosty_ok "SSH reachable"
        echo "    Running post-boot setup (update, upgrade, fetch tool)..."
        ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -o StrictHostKeyChecking=no -o BatchMode=yes "root@${vm_ip}" '
            export DEBIAN_FRONTEND=noninteractive
            apt update -y
            apt upgrade -y
            if apt-cache show neofetch >/dev/null 2>&1; then
                apt install -y neofetch
            elif apt-cache show screenfetch >/dev/null 2>&1; then
                apt install -y screenfetch
            else
                echo "Neither neofetch nor screenfetch available in repos"
            fi
        ' >/tmp/frosty_vps_postsetup_${vm_name}.log 2>&1

        if [[ $? -eq 0 ]]; then
            _frosty_ok "Post-boot setup complete (apt update/upgrade + fetch tool installed)"
        else
            _frosty_warn "Post-boot setup had issues — see /tmp/frosty_vps_postsetup_${vm_name}.log"
        fi
    fi

    echo ""
    echo -e "    ${C_CYAN:-}VM ready. Access it via:${C_RESET:-}"
    echo -e "    ${C_CYAN:-}  ssh root@$(curl -s ifconfig.me 2>/dev/null || echo YOUR_HOST_IP) -p ${vm_sshport}${C_RESET:-}"
    echo ""
    echo "  Share this VM now? [1] tmate  [2] sshx  [3] Skip"
    read -rp "  Choice [1-3]: " share_now
    case "$share_now" in
        1) vps_share_tmate <<< "$vm_name" ;;
        2) vps_share_sshx <<< "$vm_name" ;;
        *) : ;;
    esac

    return 0
}

vps_list() {
    echo ""
    echo "== VPS Instances =="
    _frosty_vps_check_stack || return 1
    virsh list --all
}

vps_dashboard() {
    echo ""
    echo -e "${C_CYAN:-}== VPS Resource Dashboard ==${C_RESET:-}"
    _frosty_vps_check_stack || return 1

    local vms
    vms="$(virsh list --all --name 2>/dev/null | grep -v '^$')"

    if [[ -z "$vms" ]]; then
        echo "  No VMs found."
        return 0
    fi

    printf "  %-20s %-10s %-8s %-8s %-8s\n" "NAME" "STATE" "vCPUs" "RAM(MB)" "DISK"
    printf "  %-20s %-10s %-8s %-8s %-8s\n" "----" "-----" "-----" "-------" "----"

    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        local state cpus mem disk
        state="$(virsh domstate "$vm" 2>/dev/null)"
        cpus="$(virsh dominfo "$vm" 2>/dev/null | grep '^CPU(s)' | awk '{print $2}')"
        mem="$(virsh dominfo "$vm" 2>/dev/null | grep '^Used memory' | awk '{print int($3/1024)}')"
        local disk_path="${FROSTY_VPS_IMG_DIR}/${vm}.qcow2"
        if [[ -f "$disk_path" ]]; then
            disk="$(qemu-img info "$disk_path" 2>/dev/null | grep 'virtual size' | awk '{print $3}')"
        else
            disk="?"
        fi
        printf "  %-20s %-10s %-8s %-8s %-8s\n" "$vm" "$state" "${cpus:-?}" "${mem:-?}" "${disk:-?}"
    done <<< "$vms"

    echo ""
    if command -v virt-top >/dev/null 2>&1; then
        echo "  (Run 'virt-top' manually for live CPU/RAM usage graphs)"
    fi
}

vps_start() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to start: " vm_name
    if virsh start "$vm_name" >/tmp/frosty_vps_start.log 2>&1; then
        _frosty_ok "'$vm_name' started"
    else
        _frosty_fail "Start failed — see /tmp/frosty_vps_start.log"
        return 1
    fi
}

vps_stop() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to stop: " vm_name
    if virsh shutdown "$vm_name" >/tmp/frosty_vps_stop.log 2>&1; then
        _frosty_ok "'$vm_name' shutdown signal sent"
    else
        _frosty_fail "Stop failed — see /tmp/frosty_vps_stop.log"
        return 1
    fi
}

vps_edit_config() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to edit: " vm_name
    if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi

    echo "  [1] Change RAM  [2] Change vCPUs  [3] Open full XML editor"
    read -rp "  Choice: " edit_choice
    case "$edit_choice" in
        1)
            read -rp "  New RAM in MB: " new_ram
            virsh shutdown "$vm_name" >/dev/null 2>&1
            sleep 3
            virsh setmaxmem "$vm_name" "${new_ram}M" --config >/dev/null 2>&1
            virsh setmem "$vm_name" "${new_ram}M" --config >/dev/null 2>&1
            virsh start "$vm_name" >/dev/null 2>&1
            _frosty_ok "RAM updated to ${new_ram}MB, VM restarted"
            ;;
        2)
            read -rp "  New vCPU count: " new_cpu
            virsh shutdown "$vm_name" >/dev/null 2>&1
            sleep 3
            virsh setvcpus "$vm_name" "$new_cpu" --config --maximum >/dev/null 2>&1
            virsh setvcpus "$vm_name" "$new_cpu" --config >/dev/null 2>&1
            virsh start "$vm_name" >/dev/null 2>&1
            _frosty_ok "vCPUs updated to ${new_cpu}, VM restarted"
            ;;
        3)
            virsh edit "$vm_name"
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
    virsh destroy "$vm_name" >/dev/null 2>&1
    virsh undefine "$vm_name" --remove-all-storage >/tmp/frosty_vps_delete.log 2>&1

    for chain in PREROUTING; do
        while iptables -t nat -L "$chain" -n --line-numbers | grep -q "frosty-${vm_name}-"; do
            local ln
            ln="$(iptables -t nat -L "$chain" -n --line-numbers | grep "frosty-${vm_name}-" | head -1 | awk '{print $1}')"
            iptables -t nat -D "$chain" "$ln" 2>/dev/null
        done
    done
    while iptables -L FORWARD -n --line-numbers | grep -q "frosty-${vm_name}-"; do
        local ln
        ln="$(iptables -L FORWARD -n --line-numbers | grep "frosty-${vm_name}-" | head -1 | awk '{print $1}')"
        iptables -D FORWARD "$ln" 2>/dev/null
    done

    rm -rf "${FROSTY_VPS_IMG_DIR}/${vm_name}-cloudinit" "${FROSTY_VPS_IMG_DIR}/${vm_name}-seed.iso" "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta"
    rm -rf "${FROSTY_VPS_SNAP_DIR}/${vm_name}"
    _frosty_ok "'$vm_name' deleted"
}

vps_snapshot_create() {
    echo ""
    _frosty_vps_check_stack || return 1
    read -rp "  VM name to snapshot: " vm_name
    if ! virsh dominfo "$vm_name" >/dev/null 2>&1; then
        _frosty_fail "VM '$vm_name' not found"
        return 1
    fi
    read -rp "  Snapshot name (e.g. before-update): " snap_name
    [[ -z "$snap_name" ]] && snap_name="snap-$(date +%Y%m%d-%H%M%S)"

    if virsh snapshot-create-as "$vm_name" "$snap_name" --description "Frosty snapshot" >/tmp/frosty_vps_snap.log 2>&1; then
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
    virsh snapshot-list "$vm_name" 2>&1
}

vps_snapshot_restore() {
    echo ""
    read -rp "  VM name: " vm_name
    virsh snapshot-list "$vm_name" 2>/dev/null
    echo ""
    read -rp "  Snapshot name to restore: " snap_name
    read -rp "  Type RESTORE to confirm reverting '$vm_name' to '$snap_name': " confirm
    if [[ "$confirm" != "RESTORE" ]]; then
        echo "Cancelled."
        return 1
    fi
    if virsh snapshot-revert "$vm_name" "$snap_name" >/tmp/frosty_vps_restore.log 2>&1; then
        _frosty_ok "'$vm_name' reverted to snapshot '$snap_name'"
    else
        _frosty_fail "Restore failed — see /tmp/frosty_vps_restore.log"
        return 1
    fi
}

vps_snapshot_delete() {
    echo ""
    read -rp "  VM name: " vm_name
    virsh snapshot-list "$vm_name" 2>/dev/null
    echo ""
    read -rp "  Snapshot name to delete: " snap_name
    if virsh snapshot-delete "$vm_name" "$snap_name" >/tmp/frosty_vps_snapdel.log 2>&1; then
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
    echo -e "${C_CYAN}║  [1] Create Snapshot                          ║${C_RESET}"
    echo -e "${C_CYAN}║  [2] List Snapshots                           ║${C_RESET}"
    echo -e "${C_CYAN}║  [3] Restore Snapshot                         ║${C_RESET}"
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

vps_firewall_add() {
    echo ""
    read -rp "  VM name: " vm_name
    local vm_ip
    vm_ip="$(_frosty_vps_ip "$vm_name")"
    if [[ -z "$vm_ip" ]]; then
        _frosty_fail "No IP on record for '$vm_name' — was it created with the current script version?"
        return 1
    fi

    read -rp "  Additional host port to forward (e.g. 25565): " new_port
    read -rp "  Guest port (usually same, e.g. 25565): " guest_port
    guest_port="${guest_port:-$new_port}"
    read -rp "  Protocol (tcp/udp) [tcp]: " proto
    proto="${proto:-tcp}"

    iptables -t nat -A PREROUTING -p "$proto" --dport "$new_port" -j DNAT --to-destination "${vm_ip}:${guest_port}" -m comment --comment "frosty-${vm_name}-${new_port}"
    iptables -A FORWARD -p "$proto" -d "$vm_ip" --dport "$guest_port" -j ACCEPT -m comment --comment "frosty-${vm_name}-${new_port}"

    _frosty_ok "Host port ${new_port}/${proto} -> ${vm_ip}:${guest_port} forwarded for '$vm_name'"
}

vps_firewall_list() {
    echo ""
    read -rp "  VM name: " vm_name
    echo "== Forwarded Ports for $vm_name =="
    iptables -t nat -L PREROUTING -n --line-numbers | grep "frosty-${vm_name}-"
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

vps_share_tmate() {
    echo ""
    echo "== Share Terminal via tmate =="
    read -rp "  VM name to access: " vm_name

    local vm_ip
    vm_ip="$(_frosty_vps_ip "$vm_name")"
    if [[ -z "$vm_ip" ]]; then
        _frosty_fail "No IP on record for '$vm_name'"
        return 1
    fi

    if ! command -v tmate >/dev/null 2>&1; then
        echo "    Installing tmate..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y tmate >/tmp/frosty_tmate_install.log 2>&1
    fi

    local tmate_sock="/tmp/frosty-tmate-${vm_name}.sock"

    if tmate -S "$tmate_sock" display -p '#{tmate_ssh}' >/dev/null 2>&1; then
        _frosty_ok "Existing tmate session for '$vm_name' is still alive — reusing it"
    else
        echo -e "    ${C_CYAN:-}Starting a new tmate session into VM '$vm_name'...${C_RESET:-}"
        rm -f "$tmate_sock"
        tmate -S "$tmate_sock" -f /dev/null new-session -d -n frosty-vps "ssh -i ${FROSTY_VPS_DIR}/frosty_vps_key -o StrictHostKeyChecking=no -t root@${vm_ip} 'command -v neofetch >/dev/null 2>&1 && neofetch || screenfetch; exec bash -l'"
        sleep 3
    fi

    echo ""
    echo -e "    ${C_YELLOW:-}Anyone with the link/command below gets a live terminal into '$vm_name':${C_RESET:-}"
    tmate -S "$tmate_sock" display -p '#{tmate_ssh}' 2>/dev/null
    tmate -S "$tmate_sock" display -p '#{tmate_web}' 2>/dev/null
}

vps_rejoin_tmate() {
    echo ""
    echo "== Rejoin Existing tmate Session =="
    read -rp "  VM name: " vm_name
    local tmate_sock="/tmp/frosty-tmate-${vm_name}.sock"

    if [[ ! -S "$tmate_sock" ]] || ! tmate -S "$tmate_sock" display -p '#{tmate_ssh}' >/dev/null 2>&1; then
        _frosty_warn "No active tmate session found for '$vm_name' — starting a new one instead"
        rm -f "$tmate_sock"
        vps_share_tmate
        return 0
    fi

    echo -e "    ${C_CYAN:-}Session is alive. Sharing details for '$vm_name':${C_RESET:-}"
    tmate -S "$tmate_sock" display -p '#{tmate_ssh}'
    tmate -S "$tmate_sock" display -p '#{tmate_web}'
}

vps_share_sshx() {
    echo ""
    echo "== Share Terminal via sshx =="
    read -rp "  VM name to access: " vm_name

    local vm_ip
    vm_ip="$(_frosty_vps_ip "$vm_name")"
    if [[ -z "$vm_ip" ]]; then
        _frosty_fail "No IP on record for '$vm_name'"
        return 1
    fi

    local sshx_log="/tmp/frosty-sshx-${vm_name}.log"
    local sshx_pidfile="/tmp/frosty-sshx-${vm_name}.pid"

    if [[ -f "$sshx_pidfile" ]] && kill -0 "$(cat "$sshx_pidfile" 2>/dev/null)" 2>/dev/null; then
        _frosty_ok "Existing sshx session for '$vm_name' is still alive"
    else
        echo -e "    ${C_CYAN:-}Starting a new sshx session into VM '$vm_name'...${C_RESET:-}"
        rm -f "$sshx_log"
        (
            ssh -i "${FROSTY_VPS_DIR}/frosty_vps_key" -o StrictHostKeyChecking=no -tt "root@${vm_ip}" "command -v sshx >/dev/null 2>&1 || curl -sSf https://sshx.io/get | sh; (command -v neofetch >/dev/null 2>&1 && neofetch || screenfetch) ; sshx" > "$sshx_log" 2>&1
        ) &
        echo $! > "$sshx_pidfile"
        sleep 8
    fi

    echo ""
    local link
    link="$(sed -r 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$sshx_log" | grep -oE 'https://sshx\.io/s/[A-Za-z0-9#]+' | tail -1)"
    if [[ -n "$link" ]]; then
        echo -e "    ${C_YELLOW:-}Share this link for a live browser terminal into '$vm_name':${C_RESET:-}"
        echo "    $link"
    else
        _frosty_warn "sshx link not detected yet — check $sshx_log manually, it may still be starting"
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
        vps_share_sshx
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

vps_expose_ssh() {
    echo ""
    echo -e "${C_CYAN:-}== Expose VPS SSH via Cloudflare Tunnel ==${C_RESET:-}"
    read -rp "  VM name to expose: " vm_name
    local vm_ip
    vm_ip="$(_frosty_vps_ip "$vm_name")"
    if [[ -z "$vm_ip" ]]; then
        _frosty_fail "No IP on record for '$vm_name'"
        return 1
    fi

    if ! command -v cloudflared >/dev/null 2>&1; then
        _frosty_fail "cloudflared not installed — go to Toolbox -> Cloudflare on the main menu first"
        return 1
    fi

    local cf_marker="${HOME}/.frosty_cloudflare_configured"
    if [[ ! -f "$cf_marker" ]]; then
        _frosty_fail "No Cloudflare tunnel connected — go to Toolbox -> Cloudflare on the main menu first"
        return 1
    fi

    read -rp "  Enter the SSH hostname you want (e.g. ssh-${vm_name}.yourdomain.com): " ssh_fqdn
    if [[ -z "$ssh_fqdn" ]]; then
        _frosty_fail "No hostname entered"
        return 1
    fi

    ssh_fqdn="${ssh_fqdn%/}"
    ssh_fqdn="${ssh_fqdn#http://}"
    ssh_fqdn="${ssh_fqdn#https://}"

    echo ""
    echo -e "${C_YELLOW:-}Now go to your Cloudflare Tunnel dashboard (one.dash.cloudflare.com${C_RESET:-}"
    echo -e "${C_YELLOW:-}-> Networks -> Tunnels -> your tunnel -> Public Hostname tab) and add:${C_RESET:-}"
    echo -e "${C_CYAN:-}    Subdomain/domain: ${ssh_fqdn}${C_RESET:-}"
    echo -e "${C_CYAN:-}    Service Type: SSH${C_RESET:-}"
    echo -e "${C_CYAN:-}    URL: ${vm_ip}:22${C_RESET:-}"
    echo ""
    read -rp "  Press Enter once you've added that route in Cloudflare..." _

    _frosty_ok "Route configured on Cloudflare's side."
    echo ""
    echo -e "    ${C_CYAN:-}Anyone with cloudflared installed can now connect via:${C_RESET:-}"
    echo -e "    ${C_CYAN:-}  cloudflared access ssh --hostname ${ssh_fqdn}${C_RESET:-}"
    echo -e "    ${C_YELLOW:-}Or add this to their ~/.ssh/config for plain 'ssh' usage:${C_RESET:-}"
    echo -e "    ${C_CYAN:-}    Host ${ssh_fqdn}${C_RESET:-}"
    echo -e "    ${C_CYAN:-}      ProxyCommand cloudflared access ssh --hostname %h${C_RESET:-}"
    echo ""
    echo "$ssh_fqdn" >> "${FROSTY_VPS_IMG_DIR}/${vm_name}.meta"
    return 0
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
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[14]${C_RESET} ${C_WHITE}Expose SSH via Cloudflare${C_RESET}               ${C_FROST}${C_BOLD}║${C_RESET}"
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
        14) vps_expose_ssh ;;
        15) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_vps_kvm_full_menu
}
