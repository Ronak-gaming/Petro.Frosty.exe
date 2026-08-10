#!/bin/bash

# ==========================================
# Frosty.exe
# All-in-One Pterodactyl Installer
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
# Startup
# ------------------------------------------

echo ""
echo -e "${ICE}❄ Initializing Frosty.exe...${RESET}"
sleep 0.4

echo -e "${ICE}❄ Loading installer...${RESET}"
sleep 0.4

echo -e "${ICE}❄ Frost Core: ${WHITE}ONLINE${RESET}"
sleep 0.4

# ------------------------------------------
# System Detection
# ------------------------------------------

echo ""
echo -e "${CYAN}╔════════════════ SYSTEM DETECTION ════════════════╗${RESET}"

# Operating System
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$PRETTY_NAME"
else
    OS_NAME="Unknown"
fi

# CPU
CPU_CORES=$(nproc 2>/dev/null || echo "Unknown")

# RAM
if command -v free >/dev/null 2>&1; then
    RAM=$(free -h | awk '/^Mem:/ {print $2}')
else
    RAM="Unknown"
fi

# Disk
DISK=$(df -h / | awk 'NR==2 {print $2}')

# Architecture
ARCH=$(uname -m)

# Kernel
KERNEL=$(uname -r)

# IPv4
IPV4=$(hostname -I 2>/dev/null | awk '{print $1}')

# ------------------------------------------
# Display
# ------------------------------------------

echo -e "${ICE}❄ Operating System : ${WHITE}${OS_NAME}${RESET}"
echo -e "${ICE}❄ CPU Cores        : ${WHITE}${CPU_CORES}${RESET}"
echo -e "${ICE}❄ RAM              : ${WHITE}${RAM}${RESET}"
echo -e "${ICE}❄ Disk             : ${WHITE}${DISK}${RESET}"
echo -e "${ICE}❄ Architecture     : ${WHITE}${ARCH}${RESET}"
echo -e "${ICE}❄ Kernel           : ${WHITE}${KERNEL}${RESET}"
echo -e "${ICE}❄ IPv4             : ${WHITE}${IPV4:-Not detected}${RESET}"

echo -e "${CYAN}╚══════════════════════════════════════════════════╝${RESET}"

# ------------------------------------------
# Result
# ------------------------------------------

echo ""
echo -e "${GREEN}[✓] System detection complete.${RESET}"
echo ""
