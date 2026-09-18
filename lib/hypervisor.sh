#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Proxmox VE installer.
#
# UNLIKE everything else Frosty.exe installs, Proxmox is not a
# service that runs alongside others — it REPLACES the running
# kernel and wants to become the base OS layer for the whole
# machine. Real official process (per pve.proxmox.com):
#   Phase 1: add repo, install proxmox-default-kernel, REBOOT
#   Phase 2 (after reboot, now on the pve kernel): install
#            proxmox-ve, remove the old Debian kernel, done
#
# This can't complete in one script run because of the reboot —
# it's split into two phases with a marker file, and the menu
# detects which phase you're in automatically.
# ============================================================

FROSTY_PROXMOX_MARKER="/var/lib/frosty-proxmox-phase1-done"

_frosty_proxmox_container_check() {
    # Proxmox needs to install and boot into its own kernel — something
    # that is simply not possible inside a container (Docker, LXC,
    # Codespaces, etc.), since a container shares the host's kernel and
    # has no kernel of its own to swap. Fail clearly here instead of
    # burning time on repo/package steps that would ultimately hit a
    # wall at the reboot.
    if [[ -f /.dockerenv ]]; then
        return 1
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"
        case "$virt" in
            docker|lxc|container|openvz|wsl) return 1 ;;
        esac
    fi
    return 0
}

show_proxmox_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}           ${C_ICE}${C_BOLD}❄  P R O X M O X  V E  ❄${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"

    if [[ -f "$FROSTY_PROXMOX_MARKER" ]]; then
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_YELLOW}Phase 1 already done — ready for Phase 2${C_RESET}     ${C_FROST}${C_BOLD}║${C_RESET}"
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Run Phase 2 (finish install)${C_RESET}             ${C_FROST}${C_BOLD}║${C_RESET}"
    else
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Run Phase 1 (install kernel + reboot)${C_RESET}    ${C_FROST}${C_BOLD}║${C_RESET}"
    fi
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[2]${C_RESET} ${C_WHITE}Back${C_RESET}                                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  ❄ Select an option [1-2]: " px_choice

    case "$px_choice" in
        1)
            if [[ -f "$FROSTY_PROXMOX_MARKER" ]]; then
                install_proxmox_phase2
            else
                install_proxmox_phase1
            fi
            ;;
        2) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
}

install_proxmox_phase1() {
    echo ""
    echo -e "${C_CYAN:-}== Proxmox VE Install — Phase 1 ==${C_RESET:-}"
    echo ""

    if ! _frosty_proxmox_container_check; then
        _frosty_fail "This host is a container (Docker/LXC/Codespaces) — Proxmox needs to install and boot its own kernel, which containers can't do"
        _frosty_warn "Proxmox VE requires a dedicated bare-metal or full-VM host, not a container"
        return 1
    fi

    if [[ ! -f /etc/debian_version ]] || ! grep -qi "bookworm\|12\." /etc/debian_version 2>/dev/null; then
        _frosty_warn "This isn't confirmed as Debian 12 (Bookworm) — Proxmox VE on Debian officially supports Bookworm/Trixie only"
        _frosty_warn "Continuing anyway may fail; Ubuntu is NOT supported for this install method"
    fi

    echo -e "${C_RED}${C_BOLD}!! WARNING !!${C_RESET}"
    echo -e "${C_YELLOW}This will install a new kernel and REBOOT this server.${C_RESET}"
    echo -e "${C_YELLOW}If this server already runs your Panel/Wings/VPS stack, a reboot${C_RESET}"
    echo -e "${C_YELLOW}will briefly interrupt all of them. Only proceed on a server you${C_RESET}"
    echo -e "${C_YELLOW}intend to dedicate to Proxmox, ideally a fresh box.${C_RESET}"
    echo ""
    read -rp "  Type INSTALL to confirm and continue: " confirm
    if [[ "$confirm" != "INSTALL" ]]; then
        echo "Cancelled."
        return 1
    fi

    dpkg --configure -a >/tmp/frosty_proxmox_dpkg_fix.log 2>&1

    echo "    Fixing /etc/hosts (Proxmox requires the hostname to resolve to a real IP)..."
    local hostname_now
    hostname_now="$(hostname)"
    local ip_now
    ip_now="${FROSTY_PUBLIC_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    if [[ -n "$ip_now" ]] && ! grep -q "$hostname_now" /etc/hosts; then
        echo "${ip_now} ${hostname_now}.local ${hostname_now}" >> /etc/hosts
    fi

    echo "    Adding Proxmox VE repository..."
    wget -q https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
        -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg 2>/tmp/frosty_proxmox_key.log
    if [[ ! -s /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg ]]; then
        _frosty_fail "Failed to download Proxmox's repository key — see /tmp/frosty_proxmox_key.log"
        return 1
    fi
    echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-install-repo.list

    echo "    Updating package lists..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_proxmox_apt.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y >>/tmp/frosty_proxmox_apt.log 2>&1

    echo "    Installing the Proxmox VE kernel (this can take a while)..."
    if ! DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y proxmox-default-kernel >>/tmp/frosty_proxmox_apt.log 2>&1; then
        _frosty_fail "Proxmox kernel install failed — see /tmp/frosty_proxmox_apt.log"
        return 1
    fi
    _frosty_ok "Proxmox kernel installed"

    touch "$FROSTY_PROXMOX_MARKER"

    echo ""
    echo -e "${C_YELLOW}${C_BOLD}Phase 1 complete. This server must now REBOOT.${C_RESET}"
    echo -e "${C_YELLOW}After it comes back up, run Frosty.exe again and choose${C_RESET}"
    echo -e "${C_YELLOW}Hypervisor -> Proxmox VE -> Run Phase 2 to finish the install.${C_RESET}"
    echo ""
    read -rp "  Reboot now? [y/n]: " reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        systemctl reboot
    else
        _frosty_warn "Not rebooting — remember Phase 2 won't work until you do"
    fi
}

install_proxmox_phase2() {
    echo ""
    echo -e "${C_CYAN:-}== Proxmox VE Install — Phase 2 ==${C_RESET:-}"
    echo ""

    if ! uname -r | grep -qi "pve"; then
        _frosty_fail "Not currently running the Proxmox kernel — did you actually reboot after Phase 1?"
        _frosty_warn "Current kernel: $(uname -r)"
        return 1
    fi
    _frosty_ok "Running on the Proxmox kernel: $(uname -r)"

    echo "    Installing Proxmox VE packages (this can take a while)..."
    if ! DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y proxmox-ve postfix open-iscsi chrony >/tmp/frosty_proxmox_phase2.log 2>&1; then
        _frosty_fail "proxmox-ve package install failed — see /tmp/frosty_proxmox_phase2.log"
        return 1
    fi
    _frosty_ok "Proxmox VE packages installed"

    echo "    Removing the old Debian kernel..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y 'linux-image-amd64' 'linux-image-6.1*' >>/tmp/frosty_proxmox_phase2.log 2>&1
    update-grub >>/tmp/frosty_proxmox_phase2.log 2>&1

    rm -f "$FROSTY_PROXMOX_MARKER"

    local web_ip="${FROSTY_PUBLIC_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    _frosty_ok "Proxmox VE installation complete"
    echo ""
    echo -e "    ${C_CYAN:-}Web UI:${C_RESET:-} https://${web_ip}:8006"
    echo -e "    ${C_YELLOW:-}Log in with your existing root/system password.${C_RESET:-}"
    echo -e "    ${C_YELLOW:-}You'll need to set up a network bridge (vmbr0) manually in the UI${C_RESET:-}"
    echo -e "    ${C_YELLOW:-}if one wasn't auto-configured — see Proxmox's networking docs.${C_RESET:-}"
}
