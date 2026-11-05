#!/usr/bin/env bash
set -uo pipefail

specs_checker() {
    echo ""
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}       ${C_ICE}${C_BOLD}❄  F R O S T Y   D E E P   S P E C S   A U D I T  ❄${C_RESET}    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""

    # ------------------------------------------------------------
    # 1. Visual Fetch Tool (neofetch / screenfetch)
    # ------------------------------------------------------------
    if ! command -v neofetch >/dev/null 2>&1 && ! command -v screenfetch >/dev/null 2>&1; then
        echo "    Installing system info fetch tool..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_specs_apt.log 2>&1
        if apt-cache show neofetch >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y neofetch >>/tmp/frosty_specs_apt.log 2>&1
        elif apt-cache show screenfetch >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y screenfetch >>/tmp/frosty_specs_apt.log 2>&1
        fi
    fi

    if command -v neofetch >/dev/null 2>&1; then
        neofetch
    elif command -v screenfetch >/dev/null 2>&1; then
        screenfetch
    fi

    # ------------------------------------------------------------
    # 2. System, CPU & Hardware Capabilities
    # ------------------------------------------------------------
    local os_pretty kernel_ver arch_name uptime_str hostname_str
    os_pretty="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown Linux}")"
    kernel_ver="$(uname -r)"
    arch_name="$(uname -m)"
    uptime_str="$(uptime -p 2>/dev/null | sed 's/^up //' || echo 'unknown')"
    hostname_str="$(hostname 2>/dev/null || echo 'unknown')"

    local cpu_model cpu_cores cpu_sockets cpu_mhz cpu_cache aes_flag virt_flag
    cpu_model="$(awk -F: '/model name/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$cpu_model" ]] && cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    [[ -z "$cpu_model" ]] && cpu_model="Unknown CPU"

    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    cpu_sockets="$(grep 'physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)"
    [[ "$cpu_sockets" -eq 0 ]] && cpu_sockets=1

    cpu_mhz="$(awk -F: '/cpu MHz/{gsub(/^[ \t]+/, "", $2); printf "%.0f MHz", $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$cpu_mhz" ]] && cpu_mhz="$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/{gsub(/^[ \t]+/, "", $2); printf "%.0f MHz", $2; exit}')"
    [[ -z "$cpu_mhz" ]] && cpu_mhz="N/A"

    cpu_cache="$(awk -F: '/cache size/{gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$cpu_cache" ]] && cpu_cache="N/A"

    if grep -q -w "aes" /proc/cpuinfo 2>/dev/null; then
        aes_flag="${C_GREEN}✓ Enabled (AES-NI)${C_RESET}"
    else
        aes_flag="${C_RED}✗ Disabled${C_RESET}"
    fi

    if grep -q -E "vmx|svm" /proc/cpuinfo 2>/dev/null; then
        virt_flag="${C_GREEN}✓ Enabled (VT-x / AMD-V)${C_RESET}"
    else
        virt_flag="${C_YELLOW}✗ Not exposed to guest${C_RESET}"
    fi

    echo ""
    echo -e "${C_FROST}${C_BOLD}╭── ❄ System & CPU Architecture ───────────────────────────────╮${C_RESET}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Hostname" "$hostname_str"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Operating System" "$os_pretty"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s (%s)${C_RESET}\n" "Kernel & Arch" "$kernel_ver" "$arch_name"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "System Uptime" "$uptime_str"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "CPU Model" "$cpu_model"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s vCPU(s) (%s Socket) @ %s (Cache: %s)${C_RESET}\n" "CPU Topology" "$cpu_cores" "$cpu_sockets" "$cpu_mhz" "$cpu_cache"
    echo -e "  ${C_ICE}Hardware Crypto       ${C_RESET} : ${aes_flag}"
    echo -e "  ${C_ICE}CPU Virtualization    ${C_RESET} : ${virt_flag}"
    echo -e "${C_FROST}${C_BOLD}╰──────────────────────────────────────────────────────────────╯${C_RESET}"

    # ------------------------------------------------------------
    # 3. Unified Memory & CPU Limits (OS-Reported vs Real cgroup)
    # ------------------------------------------------------------
    local os_mem_total os_mem_used os_mem_avail os_swap_total os_swap_used
    os_mem_total="$(free -m | awk '/^Mem:/{print $2}')"
    os_mem_used="$(free -m | awk '/^Mem:/{print $3}')"
    os_mem_avail="$(free -m | awk '/^Mem:/{print $7}')"
    os_swap_total="$(free -m | awk '/^Swap:/{print $2}')"
    os_swap_used="$(free -m | awk '/^Swap:/{print $3}')"

    local cg_mem_str="Unlimited (No container memory cap)"
    local cg_mem_mb=""
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
        local mem_max
        mem_max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
        if [[ "$mem_max" != "max" && "$mem_max" =~ ^[0-9]+$ ]]; then
            cg_mem_mb=$((mem_max / 1024 / 1024))
            cg_mem_str="${cg_mem_mb} MB (cgroup v2 enforced)"
        else
            cg_mem_str="Unlimited / Host-Level (cgroup v2: max)"
        fi
    elif [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        local mem_limit
        mem_limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
        if [[ "$mem_limit" =~ ^[0-9]+$ && "$mem_limit" -lt 9000000000000000000 ]]; then
            cg_mem_mb=$((mem_limit / 1024 / 1024))
            cg_mem_str="${cg_mem_mb} MB (cgroup v1 enforced)"
        else
            cg_mem_str="Unlimited / Host-Level (cgroup v1)"
        fi
    fi

    local cg_cpu_str="Unlimited (${cpu_cores} full host cores usable)"
    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        local cpu_max_raw quota period
        cpu_max_raw="$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
        quota="$(echo "$cpu_max_raw" | awk '{print $1}')"
        period="$(echo "$cpu_max_raw" | awk '{print $2}')"
        if [[ "$quota" != "max" && "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
            local eff_cores
            eff_cores="$(awk "BEGIN {printf \"%.2f\", $quota / $period}")"
            cg_cpu_str="${eff_cores} Cores enforced (cgroup v2: ${quota}/${period})"
        else
            cg_cpu_str="Unlimited / Host-Level (cgroup v2: max)"
        fi
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)"
        if [[ "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
            local eff_cores
            eff_cores="$(awk "BEGIN {printf \"%.2f\", $quota / $period}")"
            cg_cpu_str="${eff_cores} Cores enforced (cgroup v1: ${quota}/${period})"
        else
            cg_cpu_str="Unlimited / Host-Level (cgroup v1)"
        fi
    fi

    echo ""
    echo -e "${C_FROST}${C_BOLD}╭── ❄ Real Resource Allocation (OS vs Container cgroup) ───────╮${C_RESET}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s MB Total / %s MB Used / %s MB Available${C_RESET}\n" "OS-Reported RAM" "$os_mem_total" "$os_mem_used" "$os_mem_avail"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Real cgroup RAM Cap" "$cg_mem_str"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s MB Total / %s MB Used${C_RESET}\n" "Swap Space" "${os_swap_total:-0}" "${os_swap_used:-0}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s Cores${C_RESET}\n" "OS-Reported CPUs" "$cpu_cores"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_YELLOW}%s${C_RESET}\n" "Real cgroup CPU Cap" "$cg_cpu_str"
    echo -e "${C_FROST}${C_BOLD}╰──────────────────────────────────────────────────────────────╯${C_RESET}"

    # ------------------------------------------------------------
    # 4. Virtualization, Cloud Provider & Container Fingerprinting
    # ------------------------------------------------------------
    local virt_type="Bare Metal / Physical"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local sdv
        sdv="$(systemd-detect-virt 2>/dev/null || echo 'none')"
        [[ "$sdv" != "none" ]] && virt_type="$sdv"
    fi
    if [[ -f /.dockerenv ]]; then
        virt_type="docker (${virt_type})"
    elif grep -qa "lxc" /proc/1/environ 2>/dev/null; then
        virt_type="lxc (${virt_type})"
    fi

    local sys_vendor product_name board_name
    sys_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr -d '\0' || echo 'Unknown')"
    product_name="$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\0' || echo 'Unknown')"
    board_name="$(cat /sys/class/dmi/id/board_name 2>/dev/null | tr -d '\0' || echo 'Unknown')"

    local provider_guess="${sys_vendor} (${product_name})"
    if [[ -n "${CODESPACES:-}" || -n "${GITHUB_CODESPACE_TOKEN:-}" ]]; then
        provider_guess="GitHub Codespaces (Azure Container/VM)"
    elif grep -qi "amazon\|ec2" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="Amazon Web Services (AWS EC2)"
    elif grep -qi "google" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="Google Cloud Platform (GCP)"
    elif grep -qi "microsoft" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="Microsoft Azure"
    elif grep -qi "oracle" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="Oracle Cloud Infrastructure (OCI)"
    elif grep -qi "hetzner" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="Hetzner Cloud"
    elif grep -qi "digitalocean" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="DigitalOcean"
    elif grep -qi "ovh" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="OVHcloud"
    elif grep -qi "qemu\|bochs\|kvm" /sys/class/dmi/id/* 2>/dev/null; then
        provider_guess="KVM / QEMU Standard Virtual Machine (${sys_vendor})"
    fi

    local kvm_dev_status
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        kvm_dev_status="${C_GREEN}✓ Present & Accessible (/dev/kvm usable for nested KVM VMs)${C_RESET}"
    elif [[ -e /dev/kvm ]]; then
        kvm_dev_status="${C_YELLOW}! Present but permission restricted (chmod 666 /dev/kvm needed)${C_RESET}"
    else
        kvm_dev_status="${C_RED}✗ Not present (QEMU TCG software emulation or Docker VPS only)${C_RESET}"
    fi

    local pid1_name
    pid1_name="$(ps -p 1 -o comm= 2>/dev/null || echo 'unknown')"

    echo ""
    echo -e "${C_FROST}${C_BOLD}╭── ❄ Virtualization, Hypervisor & Cloud Provider ─────────────╮${C_RESET}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Detected Environment" "$virt_type"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Hardware / Cloud Host" "$provider_guess"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s (systemd active: %s)${C_RESET}\n" "PID 1 Init System" "$pid1_name" "$([[ -d /run/systemd/system ]] && echo 'yes' || echo 'no')"
    echo -e "  ${C_ICE}/dev/kvm Acceleration ${C_RESET} : ${kvm_dev_status}"
    echo -e "${C_FROST}${C_BOLD}╰──────────────────────────────────────────────────────────────╯${C_RESET}"

    # ------------------------------------------------------------
    # 5. Storage & Live Disk I/O Speed Benchmark
    # ------------------------------------------------------------
    local disk_summary
    disk_summary="$(df -h / 2>/dev/null | awk 'NR==2{printf "%s Total / %s Used / %s Free (%s)", $2, $3, $4, $5}')"

    echo ""
    echo -e "${C_FROST}${C_BOLD}╭── ❄ Storage & Disk I/O Benchmark ────────────────────────────╮${C_RESET}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Root Filesystem (/)" "$disk_summary"

    if command -v lsblk >/dev/null 2>&1; then
        local blk_list
        blk_list="$(lsblk -d -n -o NAME,SIZE,TYPE,ROTA 2>/dev/null | awk '$3=="disk"{rota=($4=="0"?"SSD/NVMe":"HDD/Rotational"); printf "%s (%s, %s) ", $1, $2, rota}')"
        [[ -n "$blk_list" ]] && printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Block Devices" "$blk_list"
    fi

    echo -ne "  ${C_ICE}Disk Write Speed Test ${C_RESET} : ${C_YELLOW}Running 64MB I/O test...${C_RESET}\r"
    local dd_out io_speed
    dd_out="$(dd if=/dev/zero of=/tmp/.frosty_io_test bs=1M count=64 conv=fdatasync 2>&1)"
    rm -f /tmp/.frosty_io_test
    io_speed="$(echo "$dd_out" | awk -F, 'END{gsub(/^[ \t]+/, "", $NF); print $NF}')"
    [[ -z "$io_speed" ]] && io_speed="N/A"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_GREEN}%-40s${C_RESET}\n" "Disk Write Speed" "$io_speed"
    echo -e "${C_FROST}${C_BOLD}╰──────────────────────────────────────────────────────────────╯${C_RESET}"

    # ------------------------------------------------------------
    # 6. Network, Public IP, ASN & ISP Details
    # ------------------------------------------------------------
    echo ""
    echo -e "${C_FROST}${C_BOLD}╭── ❄ Network, ASN & ISP Intelligence ─────────────────────────╮${C_RESET}"
    local ip_json pub_ip isp_org asn_info country_city ipv6_addr tcp_cc
    ip_json="$(curl -fsSL --max-time 6 https://ipinfo.io/json 2>/dev/null || true)"

    if [[ -n "$ip_json" ]]; then
        pub_ip="$(echo "$ip_json" | grep -oE '"ip":[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
        isp_org="$(echo "$ip_json" | grep -oE '"org":[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
        local city region country
        city="$(echo "$ip_json" | grep -oE '"city":[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
        region="$(echo "$ip_json" | grep -oE '"region":[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
        country="$(echo "$ip_json" | grep -oE '"country":[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
        country_city="${city:+${city}, }${region:+${region}, }${country:-Unknown}"
    else
        pub_ip="$(curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo 'Unavailable')"
        isp_org="Unavailable"
        country_city="Unavailable"
    fi

    ipv6_addr="$(curl -fsSL -6 --max-time 4 https://api64.ipify.org 2>/dev/null || echo 'Not configured / IPv4 only')"
    tcp_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 'unknown')"

    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Public IPv4" "${pub_ip:-Unavailable}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Public IPv6" "$ipv6_addr"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "ASN / ISP Provider" "${isp_org:-Unknown}"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "Datacenter Location" "$country_city"
    printf "  ${C_ICE}%-22s${C_RESET} : ${C_WHITE}%s${C_RESET}\n" "TCP Congestion Ctrl" "$tcp_cc"
    echo -e "${C_FROST}${C_BOLD}╰──────────────────────────────────────────────────────────────╯${C_RESET}"

    return 0
}

show_toolbox_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄  T O O L B O X  ❄${C_RESET}                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Cloudflare${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[2]${C_RESET} ${C_WHITE}Specs Checker${C_RESET}                            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[3]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  Select an option [1-3]: " tb_choice

    case "$tb_choice" in
        1) load_module "cloudflare.sh"; run_cloudflare_flow ;;
        2) specs_checker ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_toolbox_menu
}
