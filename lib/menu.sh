#!/usr/bin/env bash
set -uo pipefail

show_main_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄  F R O S T Y . E X E  ❄${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Pterodactyl (Panel / Wings)${C_RESET}              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Cloudflare${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[3]${C_RESET} ${C_WHITE}VPS Installer${C_RESET}                            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[4]${C_RESET} ${C_WHITE}Repair / Start All Services${C_RESET}              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[5]${C_RESET} ${C_WHITE}Exit${C_RESET}                                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""

    local frosty_choice=""
    while [[ -z "$frosty_choice" ]]; do
        read -rp "  Select an option [1-5]: " frosty_choice
    done

    case "$frosty_choice" in
        1) show_pterodactyl_menu ;;
        2) run_cloudflare_flow ;;
        3) load_module "vps.sh"; show_vps_submenu ;;
        4) load_module "repair.sh"; repair_all_services ;;
        5) echo -e "${C_CYAN}Goodbye.${C_RESET}"; exit 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to return to the main menu..." _
    show_main_menu
}

show_pterodactyl_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}        ${C_ICE}${C_BOLD}❄  P T E R O D A C T Y L  ❄${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Panel${C_RESET}                                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Wings${C_RESET}                                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[3]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-3]: " pty_choice

    case "$pty_choice" in
        1) run_panel_flow ;;
        2) run_wings_flow ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
}

run_panel_flow() {
    load_module "panel.sh"
    load_module "panel_manage.sh"

    if panel_installed; then
        show_panel_submenu
        return 0
    fi

    detect_system

    load_module "checks.sh"
    run_safety_checks

    load_module "prepare.sh"
    install_dependencies
    if [[ "$FROSTY_CHECK_FAILED" -eq 1 ]]; then
        echo -e "${C_RED}Dependency installation failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "php.sh"
    if ! install_php; then
        echo -e "${C_RED}PHP installation failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "database.sh"
    if ! install_database; then
        echo -e "${C_RED}MariaDB installation failed. Aborting.${C_RESET}"
        return 1
    fi
    if ! install_redis; then
        echo -e "${C_RED}Redis installation failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "docker.sh"
    if ! install_docker; then
        echo -e "${C_RED}Docker installation failed. Aborting.${C_RESET}"
        return 1
    fi

    if ! download_panel; then
        echo -e "${C_RED}Panel download failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "panel_env.sh"
    if ! install_composer; then
        echo -e "${C_RED}Composer installation failed. Aborting.${C_RESET}"
        return 1
    fi
    if ! configure_panel_env; then
        echo -e "${C_RED}Panel environment configuration failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "panel_db.sh"
    if ! configure_panel_database; then
        echo -e "${C_RED}Panel database configuration failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "panel_admin.sh"
    if ! create_panel_admin; then
        echo -e "${C_RED}Administrator creation failed. Aborting.${C_RESET}"
        return 1
    fi

    load_module "panel_nginx.sh"
    if ! configure_panel_nginx; then
        echo -e "${C_RED}Nginx configuration failed. Aborting.${C_RESET}"
        return 1
    fi

    echo -e "${C_CYAN}Panel installation complete.${C_RESET}"
}

run_wings_flow() {
    load_module "cloudflare.sh"
    load_module "wings.sh"

    if wings_installed; then
        show_wings_submenu
        return 0
    fi

    if ! cloudflare_configured; then
        echo ""
        echo -e "${C_YELLOW}Cloudflare must be connected before installing Wings.${C_RESET}"
        echo -e "${C_YELLOW}Go to [2] Cloudflare on the main menu first, then come back here.${C_RESET}"
        return 1
    fi
    _frosty_ok "Cloudflare connection verified"

    if ! install_wings; then
        echo -e "${C_RED}Wings installation failed.${C_RESET}"
        return 1
    fi

    echo ""
    echo -e "${C_CYAN}== Wings Domain ==${C_RESET}"
    read -rp "  Enter the FQDN you want Wings to use (e.g. wings.yourdomain.com): " wings_fqdn
    if [[ -z "$wings_fqdn" ]]; then
        _frosty_fail "No FQDN entered"
        return 1
    fi

    # Sanitize: strip protocol and trailing slash, keep just the hostname
    wings_fqdn="${wings_fqdn%/}"
    wings_fqdn="${wings_fqdn#http://}"
    wings_fqdn="${wings_fqdn#https://}"
    export FROSTY_WINGS_FQDN="$wings_fqdn"

    echo ""
    echo -e "${C_YELLOW}Now go to your Cloudflare Tunnel dashboard (one.dash.cloudflare.com${C_RESET}"
    echo -e "${C_YELLOW}-> Networks -> Tunnels -> your tunnel -> Public Hostname tab) and add:${C_RESET}"
    echo -e "${C_CYAN}    Subdomain/domain: ${wings_fqdn}${C_RESET}"
    echo -e "${C_CYAN}    Service: https://localhost:8443  (or http://localhost:8080)${C_RESET}"
    echo ""
    read -rp "  Press Enter once you've added that route in Cloudflare..." _

    if ! configure_wings; then
        echo -e "${C_RED}Wings configuration failed.${C_RESET}"
        return 1
    fi
    if ! setup_wings_service; then
        echo -e "${C_RED}Wings service setup failed.${C_RESET}"
        return 1
    fi

    echo -e "${C_CYAN}Wings installation complete. Reachable at: https://${wings_fqdn}${C_RESET}"
}

run_cloudflare_flow() {
    load_module "cloudflare.sh"

    if cloudflare_configured; then
        show_cloudflare_submenu
        return 0
    fi

    if ! install_cloudflared; then
        echo -e "${C_RED}cloudflared installation failed.${C_RESET}"
        return 1
    fi
    if ! connect_cloudflare_token; then
        echo -e "${C_RED}Cloudflare tunnel connection failed.${C_RESET}"
        return 1
    fi
}
