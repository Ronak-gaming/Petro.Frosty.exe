#!/bin/bash

# ==========================================
# Frosty.exe
# All-in-One Pterodactyl Installer
# ==========================================

clear

# Colors
CYAN='\033[1;36m'
ICE='\033[0;96m'
WHITE='\033[1;97m'
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
# Frost Loading Animation
# ------------------------------------------

echo ""

frames=(
    "❄"
    "❄ ❄"
    "❄ ❄ ❄"
    "❄ ❄ ❄ ❄"
    "❄ ❄ ❄ ❄ ❄"
)

for frame in "${frames[@]}"; do
    printf "\r${CYAN}[%s] Frost Core Initializing...${RESET}" "$frame"
    sleep 0.25
done

echo ""

# ------------------------------------------
# Startup Status
# ------------------------------------------

echo -e "${ICE}❄ Initializing Frosty.exe...${RESET}"
sleep 0.4

echo -e "${ICE}❄ Loading installer...${RESET}"
sleep 0.4

echo -e "${ICE}❄ Frost Core: ${WHITE}ONLINE${RESET}"
sleep 0.4

echo ""
echo -e "${CYAN}[✓] Frosty.exe started successfully${RESET}"
echo ""
