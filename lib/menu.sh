#!/usr/bin/env bash
set -uo pipefail

_frosty_reveal() {
    local delay=0.025
    if [[ ! -t 1 ]]; then delay=0; fi
    for line in "$@"; do
        echo -e "$line"
        [[ "$delay" != "0" ]] && sleep "$delay"
    done
}

# ════════════════════════════════════════════════════════════════════════
#  FROSTYY INSTALLER — main screen (framed block-letter banner + arrow-key menu)
# ════════════════════════════════════════════════════════════════════════
FROSTY_MENU_ITEMS=("Panels & VPS Bot" "Toolbox" "VPS Installer" "Repair / Start All Services" "Hypervisor" "Exit")
FROSTY_PICK=""

FROSTY_BANNER_LINES=(
    '         \e[38;5;75m███████\e[38;5;31m╗\e[38;5;75m██████\e[38;5;31m╗\e[0m  \e[38;5;75m██████\e[38;5;31m╗\e[0m \e[38;5;75m███████\e[38;5;31m╗\e[38;5;75m████████\e[38;5;31m╗\e[38;5;75m██\e[38;5;31m╗\e[0m   \e[38;5;75m██\e[38;5;31m╗\e[38;5;75m██\e[38;5;31m╗\e[0m   \e[38;5;75m██\e[38;5;31m╗\e[0m         '
    '         \e[38;5;81m██\e[38;5;31m╔════╝\e[38;5;81m██\e[38;5;31m╔══\e[38;5;81m██\e[38;5;31m╗\e[38;5;81m██\e[38;5;31m╔═══\e[38;5;81m██\e[38;5;31m╗\e[38;5;81m██\e[38;5;31m╔════╝╚══\e[38;5;81m██\e[38;5;31m╔══╝╚\e[38;5;81m██\e[38;5;31m╗\e[0m \e[38;5;81m██\e[38;5;31m╔╝╚\e[38;5;81m██\e[38;5;31m╗\e[0m \e[38;5;81m██\e[38;5;31m╔╝\e[0m         '
    '  \e[1;38;5;51m❄\e[0m      \e[38;5;45m█████\e[38;5;31m╗\e[0m  \e[38;5;45m██████\e[38;5;31m╔╝\e[38;5;45m██\e[38;5;31m║\e[0m   \e[38;5;45m██\e[38;5;31m║\e[38;5;45m███████\e[38;5;31m╗\e[0m   \e[38;5;45m██\e[38;5;31m║\e[0m    \e[38;5;31m╚\e[38;5;45m████\e[38;5;31m╔╝\e[0m  \e[38;5;31m╚\e[38;5;45m████\e[38;5;31m╔╝\e[0m       \e[1;38;5;51m❄\e[0m  '
    '         \e[38;5;51m██\e[38;5;31m╔══╝\e[0m  \e[38;5;51m██\e[38;5;31m╔══\e[38;5;51m██\e[38;5;31m╗\e[38;5;51m██\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║╚════\e[38;5;51m██\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║\e[0m     \e[38;5;31m╚\e[38;5;51m██\e[38;5;31m╔╝\e[0m    \e[38;5;31m╚\e[38;5;51m██\e[38;5;31m╔╝\e[0m           '
    '         \e[38;5;51m██\e[38;5;31m║\e[0m     \e[38;5;51m██\e[38;5;31m║\e[0m  \e[38;5;51m██\e[38;5;31m║╚\e[38;5;51m██████\e[38;5;31m╔╝\e[38;5;51m███████\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║\e[0m      \e[38;5;51m██\e[38;5;31m║\e[0m      \e[38;5;51m██\e[38;5;31m║\e[0m            '
    '         \e[38;5;31m╚═╝\e[0m     \e[38;5;31m╚═╝\e[0m  \e[38;5;31m╚═╝\e[0m \e[38;5;31m╚═════╝\e[0m \e[38;5;31m╚══════╝\e[0m   \e[38;5;31m╚═╝\e[0m      \e[38;5;31m╚═╝\e[0m      \e[38;5;31m╚═╝\e[0m            '
    '    \e[38;5;75m██\e[38;5;31m╗\e[38;5;75m███\e[38;5;31m╗\e[0m   \e[38;5;75m██\e[38;5;31m╗\e[38;5;75m███████\e[38;5;31m╗\e[38;5;75m████████\e[38;5;31m╗\e[0m \e[38;5;75m█████\e[38;5;31m╗\e[0m \e[38;5;75m██\e[38;5;31m╗\e[0m     \e[38;5;75m██\e[38;5;31m╗\e[0m     \e[38;5;75m███████\e[38;5;31m╗\e[38;5;75m██████\e[38;5;31m╗\e[0m     '
    '    \e[38;5;81m██\e[38;5;31m║\e[38;5;81m████\e[38;5;31m╗\e[0m  \e[38;5;81m██\e[38;5;31m║\e[38;5;81m██\e[38;5;31m╔════╝╚══\e[38;5;81m██\e[38;5;31m╔══╝\e[38;5;81m██\e[38;5;31m╔══\e[38;5;81m██\e[38;5;31m╗\e[38;5;81m██\e[38;5;31m║\e[0m     \e[38;5;81m██\e[38;5;31m║\e[0m     \e[38;5;81m██\e[38;5;31m╔════╝\e[38;5;81m██\e[38;5;31m╔══\e[38;5;81m██\e[38;5;31m╗\e[0m    '
    '    \e[38;5;45m██\e[38;5;31m║\e[38;5;45m██\e[38;5;31m╔\e[38;5;45m██\e[38;5;31m╗\e[0m \e[38;5;45m██\e[38;5;31m║\e[38;5;45m███████\e[38;5;31m╗\e[0m   \e[38;5;45m██\e[38;5;31m║\e[0m   \e[38;5;45m███████\e[38;5;31m║\e[38;5;45m██\e[38;5;31m║\e[0m     \e[38;5;45m██\e[38;5;31m║\e[0m     \e[38;5;45m█████\e[38;5;31m╗\e[0m  \e[38;5;45m██████\e[38;5;31m╔╝\e[0m    '
    '    \e[38;5;51m██\e[38;5;31m║\e[38;5;51m██\e[38;5;31m║╚\e[38;5;51m██\e[38;5;31m╗\e[38;5;51m██\e[38;5;31m║╚════\e[38;5;51m██\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m╔══\e[38;5;51m██\e[38;5;31m║\e[38;5;51m██\e[38;5;31m║\e[0m     \e[38;5;51m██\e[38;5;31m║\e[0m     \e[38;5;51m██\e[38;5;31m╔══╝\e[0m  \e[38;5;51m██\e[38;5;31m╔══\e[38;5;51m██\e[38;5;31m╗\e[0m    '
    '    \e[38;5;51m██\e[38;5;31m║\e[38;5;51m██\e[38;5;31m║\e[0m \e[38;5;31m╚\e[38;5;51m████\e[38;5;31m║\e[38;5;51m███████\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║\e[0m   \e[38;5;51m██\e[38;5;31m║\e[0m  \e[38;5;51m██\e[38;5;31m║\e[38;5;51m███████\e[38;5;31m╗\e[38;5;51m███████\e[38;5;31m╗\e[38;5;51m███████\e[38;5;31m╗\e[38;5;51m██\e[38;5;31m║\e[0m  \e[38;5;51m██\e[38;5;31m║\e[0m    '
    '    \e[38;5;31m╚═╝╚═╝\e[0m  \e[38;5;31m╚═══╝╚══════╝\e[0m   \e[38;5;31m╚═╝\e[0m   \e[38;5;31m╚═╝\e[0m  \e[38;5;31m╚═╝╚══════╝╚══════╝╚══════╝╚═╝\e[0m  \e[38;5;31m╚═╝\e[0m    '
)

declare -F _frosty_menu_row >/dev/null 2>&1 || _frosty_menu_row() {
    local color="$1" label="$2" text="$3" pad
    pad=$(( 45 - ${#label} - ${#text} )); (( pad < 1 )) && pad=1
    printf '%b\n' "${C_FROST}${C_BOLD}║${C_RESET}  ${color}${label}${C_RESET} ${C_WHITE}${text}${C_RESET}$(printf '%*s' "$pad" '')${C_FROST}${C_BOLD}║${C_RESET}"
}

# one menu row inside the inner rounded box (74 visible columns)
_frosty_main_row() {
    local i="$1" sel="$2" label="${FROSTY_MENU_ITEMS[$(( $1 - 1 ))]}"
    local F="${C_CYAN}${C_BOLD}" R="${C_RESET}" content pad
    pad=$(( 62 - ${#label} )); (( pad < 0 )) && pad=0
    if [[ "$sel" == "1" ]]; then
        content="  \e[48;5;17m\e[1;38;5;51m❯❯\e[0m   ${C_CYAN}${C_BOLD}[${i}]${R}  \e[48;5;24m\e[1;38;5;255m${label}$(printf '%*s' "$pad" '')\e[0m"
    else
        content="  ${C_BLUE}${C_BOLD}❯❯${R}   ${C_CYAN}${C_BOLD}[${i}]${R}  ${C_WHITE}${label}${R}$(printf '%*s' "$pad" '')"
    fi
    printf '%b\n' "${F}┃${R} ${F}│${R}${content}${F}│${R} ${F}┃${R}"
}

_frosty_main_prompt_line() {   # $1 = typed text
    local F="${C_CYAN}${C_BOLD}" R="${C_RESET}" typed="${1:-}" pad
    pad=$(( 78 - 27 - ${#typed} ))
    printf '\r\033[2K%b' "${F}┃${R} ${C_ICE}${C_BOLD}❄${R} ${C_WHITE}Select an option [1-6]:${R} ${typed}$(printf '%*s' "$pad" '')${F}┃${R}"
    printf '\r\033[28C'
}

_frosty_main_draw() {          # $1 = selected row
    local sel="$1" F="${C_CYAN}${C_BOLD}" R="${C_RESET}" l i
    printf '%b\n' "${F}┏$(_frosty_rule 78 ━)┓${R}"
    printf '%b\n' "${F}┃◤$(_frosty_rule 76 ─)◥┃${R}"
    for l in "${FROSTY_BANNER_LINES[@]}"; do
        printf '%b\n' "${F}┃${R}${l}${F}┃${R}"
    done

    local sub sublen a b
    sub="${F}»»»${R}  ${F}A L L - I N - O N E   I N S T A L L E R${R}  ${F}«««${R}"
    sublen="$(_frosty_vlen "$sub")"
    a=$(( (78 - 4 - sublen) / 2 )); b=$(( 78 - 4 - sublen - a ))
    printf '%b\n' "${F}┣◀$(_frosty_rule "$a" ━) ${R}${sub}${F} $(_frosty_rule "$b" ━)▶┫${R}"
    printf '%b\n' "${F}┃${R}$(printf '%*s' 78 '')${F}┃${R}"

    printf '%b\n' "${F}┃${R} ${F}╭$(_frosty_rule 74 ─)╮${R} ${F}┃${R}"
    for i in 1 2 3 4 5 6; do
        _frosty_main_row "$i" "$([[ "$i" == "$sel" ]] && echo 1 || echo 0)"
    done
    printf '%b\n' "${F}┃${R} ${F}╰$(_frosty_rule 74 ─)╯${R} ${F}┃${R}"

    local foot flen fl fr
    foot="${C_ICE}${C_BOLD}❄${R} ${C_WHITE}Created and maintained by${R} ${C_CYAN}${C_BOLD}Ronak Gaming${R} ${C_ICE}${C_BOLD}❄${R}"
    flen="$(_frosty_vlen "$foot")"
    fl=$(( (78 - 4 - flen) / 2 )); fr=$(( 78 - 4 - flen - fl ))
    printf '%b\n' "${F}┃${R} ${C_CYAN}$(_frosty_rule "$fl" ─)${R} ${foot} ${C_CYAN}$(_frosty_rule "$fr" ─)${R} ${F}┃${R}"

    _frosty_main_prompt_line ""
    printf '\n'
    printf '%b\n' "${F}┃◣$(_frosty_rule 76 ─)◢┃${R}"
    printf '%b' "${F}┗$(_frosty_rule 78 ━)┛${R}"
}

_frosty_main_redraw_rows() {   # cursor is on the prompt line
    local sel="$1" i
    printf '\033[8A\r'
    for i in 1 2 3 4 5 6; do
        _frosty_main_row "$i" "$([[ "$i" == "$sel" ]] && echo 1 || echo 0)"
    done
    printf '\033[2B'
    _frosty_main_prompt_line ""
}

_frosty_ui_can_full() {
    [[ -t 0 && -t 1 ]] || return 1
    local cols lines
    cols="$(tput cols 2>/dev/null || echo 0)"; lines="$(tput lines 2>/dev/null || echo 0)"
    [[ "$cols" =~ ^[0-9]+$ && "$lines" =~ ^[0-9]+$ ]] || return 1
    (( cols >= 80 && lines >= 30 ))
}

# Full screen: arrow keys / j k move the highlight, Enter selects, 1-6 select directly, q exits.
# Throw away anything typed/buffered before the menu was ready (extra Enter while the installer was
# downloading, or terminals that send CR+LF) so it can never auto-select an option.
_frosty_drain_stdin() {
    local _junk
    while IFS= read -rsn1 -t 0.2 _junk; do :; done
}

_frosty_main_menu_pick() {
    local sel=1 key rest
    _frosty_main_draw "$sel"
    printf '\033[2A'
    _frosty_main_prompt_line ""
    _frosty_drain_stdin
    while true; do
        IFS= read -rsn1 key || { FROSTY_PICK=6; break; }
        case "$key" in
            $'\x1b')
                rest=""; IFS= read -rsn2 -t 0.1 rest
                case "$rest" in
                    '[A'|'OA') (( sel > 1 )) && sel=$(( sel - 1 )) || sel=6 ;;
                    '[B'|'OB') (( sel < 6 )) && sel=$(( sel + 1 )) || sel=1 ;;
                    '[H') sel=1 ;;
                    '[F') sel=6 ;;
                esac
                ;;
            ''|$'\n'|$'\r') FROSTY_PICK="$sel"; break ;;
            [1-6]) FROSTY_PICK="$key"; _frosty_main_prompt_line "$key"; break ;;
            q|Q) FROSTY_PICK=6; break ;;
            k|K) (( sel > 1 )) && sel=$(( sel - 1 )) || sel=6 ;;
            j|J) (( sel < 6 )) && sel=$(( sel + 1 )) || sel=1 ;;
        esac
        _frosty_main_redraw_rows "$sel"
    done
    printf '\033[2B\r\n'
}

# Narrow terminals / pipes: compact framed list with a typed prompt.
_frosty_main_menu_compact() {
    local i colors=("$C_CYAN" "$C_PURPLE" "$C_BLUE" "$C_ICE" "$C_PURPLE" "$C_RED")
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔════════════════════════════════════════════════╗${C_RESET}"
    for i in 1 2 3 4 5 6; do
        _frosty_menu_row "${colors[$(( i - 1 ))]}" "❯ [${i}]" "${FROSTY_MENU_ITEMS[$(( i - 1 ))]}"
    done
    echo -e "${C_FROST}${C_BOLD}╠════════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}$(_frosty_center "${C_ICE}❄${C_RESET} ${C_WHITE}Created and maintained by${C_RESET} ${C_CYAN}${C_BOLD}Ronak Gaming${C_RESET} ${C_ICE}❄${C_RESET}" 48)${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    local choice=""
    [[ -t 0 ]] && _frosty_drain_stdin
    while [[ -z "$choice" ]]; do
        read -erp "  ❄ Select an option [1-6]: " choice || { choice=6; break; }
    done
    FROSTY_PICK="$choice"
}

_frosty_main_dispatch() {
    case "$1" in
        1) show_panels_menu ;;
        2) load_module "toolbox.sh"; show_toolbox_menu ;;
        3) show_vps_type_menu ;;
        4) load_module "repair.sh"; repair_all_services ;;
        5) load_module "hypervisor.sh"; show_hypervisor_menu ;;
        6) echo -e "${C_CYAN}❄ Goodbye.${C_RESET}"; exit 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
}

show_main_menu() {
    while true; do
        clear
        FROSTY_PICK=""
        if _frosty_ui_can_full; then
            _frosty_main_menu_pick
        else
            _frosty_main_menu_compact
        fi
        _frosty_main_dispatch "$FROSTY_PICK"
        echo ""
        read -rp "  Press Enter to return to the main menu..." _ || exit 0
    done
}

show_vps_type_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}      ${C_ICE}${C_BOLD}🧊 V P S   I N S T A L L E R 🧊${C_RESET}       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}❯ [1]${C_RESET} ${C_WHITE}KVM VPS${C_RESET}      ${C_ICE}(real VM, faster)${C_RESET}         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}❯ [2]${C_RESET} ${C_WHITE}Docker VPS${C_RESET}   ${C_ICE}(no KVM needed)${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}❯ [3]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  ❄ Select an option [1-3]: " vt_choice

    case "$vt_choice" in
        1) load_module "vps.sh"; show_vps_kvm_menu ;;
        2) load_module "vps_docker.sh"; show_vps_docker_menu ;;
        3) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
}

show_hypervisor_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}          ${C_ICE}${C_BOLD}❄  H Y P E R V I S O R  ❄${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Proxmox VE${C_RESET}                               ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[2]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  ❄ Select an option [1-2]: " hv_choice

    case "$hv_choice" in
        1) show_proxmox_menu ;;
        2) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
}

show_panels_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}     ${C_ICE}${C_BOLD}🧊 P A N E L S   &   V P S   B O T 🧊${C_RESET}     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}❯ [1]${C_RESET} ${C_WHITE}Petro (Pterodactyl)${C_RESET}                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}❯ [2]${C_RESET} ${C_WHITE}JTG Panel${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}❯ [3]${C_RESET} ${C_WHITE}VPS Bot${C_RESET}                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}❯ [4]${C_RESET} ${C_WHITE}PufferPanel${C_RESET}                            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}❯ [5]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  ❄ Select an option [1-5]: " panels_choice

    case "$panels_choice" in
        1) show_pterodactyl_menu ;;
        2) load_module "jtg_panel.sh"; run_jtg_panel_flow ;;
        3) load_module "vps_bot.sh"; run_vps_bot_flow ;;
        4) load_module "pufferpanel.sh"; run_pufferpanel_flow ;;
        5) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac
}

show_pterodactyl_menu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}              ${C_ICE}${C_BOLD}🧊 P E T R O 🧊${C_RESET}                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}❯ [1]${C_RESET} ${C_WHITE}Panel${C_RESET}                                  ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}❯ [2]${C_RESET} ${C_WHITE}Wings${C_RESET}                                  ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}❯ [3]${C_RESET} ${C_WHITE}Themes & Extensions${C_RESET}                    ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}❯ [4]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                      ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -erp "  ❄ Select an option [1-4]: " pty_choice

    case "$pty_choice" in
        1) run_panel_flow ;;
        2) run_wings_flow ;;
        3) load_module "panel_themes.sh"; run_themes_flow ;;
        4) return 0 ;;
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

    echo -e "${C_CYAN}❄ Panel installation complete.${C_RESET}"
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
        echo -e "${C_YELLOW}Go to Toolbox -> Cloudflare on the main menu first, then come back here.${C_RESET}"
        return 1
    fi
    _frosty_ok "Cloudflare connection verified"

    if ! install_wings; then
        echo -e "${C_RED}Wings installation failed.${C_RESET}"
        return 1
    fi

    echo ""
    echo -e "${C_CYAN}== Wings Domain ==${C_RESET}"
    read -erp "  Enter the FQDN you want Wings to use (e.g. wings.yourdomain.com): " wings_fqdn
    if [[ -z "$wings_fqdn" ]]; then
        _frosty_fail "No FQDN entered"
        return 1
    fi

    wings_fqdn="${wings_fqdn%/}"
    wings_fqdn="${wings_fqdn#http://}"
    wings_fqdn="${wings_fqdn#https://}"
    export FROSTY_WINGS_FQDN="$wings_fqdn"

    echo ""
    echo -e "${C_YELLOW}Now go to your Cloudflare Tunnel dashboard (one.dash.cloudflare.com${C_RESET}"
    echo -e "${C_YELLOW}-> Networks -> Tunnels -> your tunnel -> Public Hostname tab) and add:${C_RESET}"
    echo -e "${C_CYAN}    Subdomain/domain: ${wings_fqdn}${C_RESET}"
    echo -e "${C_CYAN}    Service: http://localhost:8443${C_RESET}"
    echo -e "${C_YELLOW}    (must be http:// — Wings runs plain HTTP on 8443; Cloudflare terminates HTTPS)${C_RESET}"
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

    _frosty_wings_verify_public "$wings_fqdn"
    _frosty_wings_print_node_checklist "$wings_fqdn"

    echo ""
    echo -e "${C_CYAN}❄ Wings installation complete. Public URL: https://${wings_fqdn}${C_RESET}"
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
