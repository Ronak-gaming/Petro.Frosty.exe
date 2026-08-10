#!/bin/bash

# ==========================================
# Frosty.exe
# All-in-One Pterodactyl Installer
# ==========================================

clear

CYAN='\033[1;36m'
ICE='\033[0;96m'
WHITE='\033[1;97m'
GREEN='\033[1;32m'
RESET='\033[0m'

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

sleep 1

echo ""
echo -e "${ICE}❄ Initializing Frosty.exe...${RESET}"
sleep 0.5

echo -e "${ICE}❄ Loading installer...${RESET}"
sleep 0.5

echo -e "${ICE}❄ Frost Core: ${WHITE}ONLINE${RESET}"
sleep 0.5

echo ""
echo -e "${CYAN}╔════════════════ SYSTEM DETECTION ════════════════╗${RESET}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OSNAME="$PRETTY_NAME"
else
    OSNAME="Unknown"
fi

CPUCORES=$(nproc 2>/dev/null || echo "Unknown")

if command -v free >/dev/null 2>&1; then
    RAM=$(free -h | awk '/^Mem:/ {print $2}')
else
    RAM="Unknown"
fi

DISK=$(df -h / | awk 'NR==2 {print $2}')

ARCH=$(uname -m)

KERNEL=$(uname -r)

IPV4=$(hostname -I 2>/dev/null | awk '{print $1}')

echo -e "${ICE}❄ Operating System : ${WHITE}${OSNAME}${RESET}"
echo -e "${ICE}❄ CPU Cores        : ${WHITE}${CPUCORES}${RESET}"
echo -e "${ICE}❄ RAM              : ${WHITE}${RAM}${RESET}"
echo -e "${ICE}❄ Disk             : ${WHITE}${DISK}${RESET}"
echo -e "${ICE}❄ Architecture     : ${WHITE}${ARCH}${RESET}"
echo -e "${ICE}❄ Kernel           : ${WHITE}${KERNEL}${RESET}"
echo -e "${ICE}❄ IPv4             : ${WHITE}${IPV4:-Not detected}${RESET}"

echo -e "${CYAN}╚══════════════════════════════════════════════════╝${RESET}"

echo ""
echo -e "${GREEN}[✓] System detection complete.${RESET}"
echo ""
