#!/bin/bash

# ==========================================
# Frosty.exe
# All-in-One Pterodactyl Installer
# Phase 2 - Step 1
# ==========================================

clear

# ------------------------------------------
# Colors
# ------------------------------------------

CYAN='\033[1;36m'
ICE='\033[0;96m'
WHITE='\033[1;97m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

# ------------------------------------------
# Frosty Banner
# ------------------------------------------

echo -e "${CYAN}"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║                                              ║"
echo -e "║          ${WHITE}❄  F R O S T Y . E X E  ❄${CYAN}          ║"
echo "║                                              ║"
echo -e "║          ${ICE}❄  ALL-IN-ONE INSTALLER  ❄${CYAN}         ║"
echo "║                                              ║"
echo "║       ❄  ❄  ❄  ❄  ❄  ❄  ❄  ❄              ║"
echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${RESET}"

sleep 0.5

# ------------------------------------------
# Root Check
# ------------------------------------------

echo ""
echo -e "${ICE}❄ Checking administrator privileges...${RESET}"

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo -e "${RED}[✗] Frosty.exe must be run as root.${RESET}"
    echo ""
    echo "Please run:"
    echo ""
    echo "sudo bash install.sh"
    echo ""
    exit 1
fi

echo -e "${GREEN}[✓] Root access confirmed.${RESET}"

# ------------------------------------------
# Operating System Check
# ------------------------------------------

echo ""
echo -e "${ICE}❄ Checking operating system...${RESET}"

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[✗] Cannot identify operating system.${RESET}"
    exit 1
fi

. /etc/os-release

echo -e "${ICE}❄ Detected: ${WHITE}${PRETTY_NAME}${RESET}"

case "$ID" in
    ubuntu|debian)
        echo -e "${GREEN}[✓] Supported operating system.${RESET}"
        ;;
    *)
        echo -e "${YELLOW}[!] This OS has not been tested by Frosty.exe.${RESET}"
        echo -e "${YELLOW}[!] Installation will not continue automatically.${RESET}"
        exit 1
        ;;
esac

# ------------------------------------------
# Basic Command Check
# ------------------------------------------

echo ""
echo -e "${ICE}❄ Checking required system commands...${RESET}"

COMMANDS="curl wget systemctl"

for COMMAND in $COMMANDS; do
    if command -v "$COMMAND" >/dev/null 2>&1; then
        echo -e "${GREEN}[✓] ${COMMAND}${RESET}"
    else
        echo -e "${YELLOW}[!] ${COMMAND} is missing.${RESET}"
    fi
done

# ------------------------------------------
# Final Result
# ------------------------------------------

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║        ✓ SYSTEM CHECK PASSED                ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "${ICE}❄ Frosty.exe is ready for the next stage.${RESET}"
echo ""
