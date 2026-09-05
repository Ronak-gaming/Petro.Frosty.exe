#!/usr/bin/env bash
set -uo pipefail

FROSTY_BLUEPRINT_RC="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}/.blueprintrc"
FROSTY_BLUEPRINT_BIN="/usr/local/bin/blueprint"

# Resolves a working blueprint command — prefers the fixed install
# location directly instead of relying on PATH/`command -v`, since PATH
# has proven inconsistent in this environment (a file can exist on disk
# at the known path while `which`/`command -v` still fail to find it).
# Also force-fixes the exec bit, since blueprint.sh has been observed to
# create this file without it set.
_frosty_blueprint_cmd() {
    if [[ -f "$FROSTY_BLUEPRINT_BIN" ]]; then
        chmod +x "$FROSTY_BLUEPRINT_BIN" 2>/dev/null
        echo "$FROSTY_BLUEPRINT_BIN"
        return 0
    fi
    if command -v blueprint >/dev/null 2>&1; then
        local resolved
        resolved="$(command -v blueprint)"
        chmod +x "$resolved" 2>/dev/null
        echo "$resolved"
        return 0
    fi
    echo ""
    return 1
}

blueprint_installed() {
    [[ -n "$(_frosty_blueprint_cmd)" ]]
}

install_blueprint() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Blueprint Framework ==${C_RESET:-}"

    if blueprint_installed; then
        _frosty_ok "Blueprint already installed"
        return 0
    fi

    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"
    if [[ ! -d "$panel_dir" ]]; then
        _frosty_fail "Panel directory not found at ${panel_dir} — install the Panel first"
        return 1
    fi

    echo "    Installing Node.js 22 (required by Blueprint)..."
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d v)" -lt 18 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gnupg unzip wget zip >/tmp/frosty_blueprint_deps.log 2>&1
        mkdir -p /etc/apt/keyrings
        timeout 60 curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>/dev/null | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_blueprint_node.log 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >>/tmp/frosty_blueprint_node.log 2>&1
    fi
    if ! command -v node >/dev/null 2>&1; then
        _frosty_fail "Node.js install failed — see /tmp/frosty_blueprint_node.log"
        return 1
    fi
    _frosty_ok "Node.js: $(node -v)"

    if ! command -v yarn >/dev/null 2>&1; then
        echo "    Installing Yarn..."
        npm i -g yarn >/tmp/frosty_blueprint_yarn.log 2>&1
    fi
    if ! command -v yarn >/dev/null 2>&1; then
        _frosty_fail "Yarn install failed — see /tmp/frosty_blueprint_yarn.log"
        return 1
    fi
    _frosty_ok "Yarn: $(yarn -v)"

    echo "    Installing panel JS dependencies (this can take a few minutes)..."
    ( cd "$panel_dir" && timeout 600 yarn install >/tmp/frosty_blueprint_yarndeps.log 2>&1 )
    if [[ $? -ne 0 ]]; then
        _frosty_fail "yarn install failed — see /tmp/frosty_blueprint_yarndeps.log"
        return 1
    fi
    _frosty_ok "Panel JS dependencies installed"

    echo "    Downloading Blueprint..."
    rm -f "${panel_dir}/release.zip"
    local latest_url="https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip"
    if ! timeout 120 curl -fL -o "${panel_dir}/release.zip" "$latest_url" >/tmp/frosty_blueprint_download.log 2>&1; then
        _frosty_fail "Blueprint download failed (HTTP error or timeout) — see /tmp/frosty_blueprint_download.log"
        return 1
    fi

    if ! unzip -t "${panel_dir}/release.zip" >/tmp/frosty_blueprint_verify.log 2>&1; then
        _frosty_fail "Downloaded file isn't a valid zip — see /tmp/frosty_blueprint_verify.log"
        echo "    -- what we actually got (first 300 bytes) --"
        head -c 300 "${panel_dir}/release.zip" | sed 's/^/    /'
        echo ""
        file "${panel_dir}/release.zip" 2>/dev/null | sed 's/^/    /'
        _frosty_warn "Kept at ${panel_dir}/release.zip for inspection"
        return 1
    fi

    echo "    Extracting Blueprint into the panel..."
    ( cd "$panel_dir" && unzip -o release.zip >/tmp/frosty_blueprint_extract.log 2>&1 )
    rm -f "${panel_dir}/release.zip"

    cat > "$FROSTY_BLUEPRINT_RC" << BPRC
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
BPRC

    chown -R www-data:www-data "$panel_dir"

    if [[ -f "${panel_dir}/blueprint.sh" ]]; then
        chmod +x "${panel_dir}/blueprint.sh"
        echo "    Running Blueprint's own installer..."
        ( cd "$panel_dir" && bash blueprint.sh >/tmp/frosty_blueprint_setup.log 2>&1 )
    else
        _frosty_fail "blueprint.sh not found after extraction"
        ls -la "$panel_dir" | head -20 | sed 's/^/    /'
    fi

    hash -r
    local bp_bin
    bp_bin="$(_frosty_blueprint_cmd)"
    if [[ -n "$bp_bin" ]]; then
        _frosty_ok "Blueprint installed: $("$bp_bin" -v 2>/dev/null || echo 'version unknown')"
        return 0
    else
        _frosty_fail "Blueprint install did not complete — check /tmp/frosty_blueprint_setup.log"
        echo "    -- searching for a blueprint binary --"
        find "$panel_dir" /usr/local/bin -maxdepth 2 -iname "blueprint*" 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

blueprint_list_installed() {
    echo ""
    echo -e "${C_CYAN:-}== Installed Extensions/Themes ==${C_RESET:-}"
    local bp_bin
    bp_bin="$(_frosty_blueprint_cmd)"
    if [[ -z "$bp_bin" ]]; then
        _frosty_warn "Blueprint isn't installed yet"
        return 1
    fi
    "$bp_bin" -list 2>&1
}

blueprint_install_open_extension() {
    local key="$1"
    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"
    local bp_bin
    bp_bin="$(_frosty_blueprint_cmd)"
    if [[ -z "$bp_bin" ]]; then
        _frosty_fail "Blueprint isn't installed — install it first (option 1)"
        return 1
    fi

    echo ""
    echo -e "${C_CYAN:-}== Installing extension: ${key} ==${C_RESET:-}"
    ( cd "$panel_dir" && timeout 120 "$bp_bin" -install "$key" 2>&1 | tee "/tmp/frosty_blueprint_install_${key}.log" )
    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        _frosty_ok "'${key}' installed"
    else
        _frosty_fail "'${key}' install failed — see /tmp/frosty_blueprint_install_${key}.log"
        return 1
    fi
}

blueprint_install_from_file() {
    echo ""
    echo -e "${C_CYAN:-}== Install Purchased Theme/Extension (.blueprint file) ==${C_RESET:-}"
    echo -e "${C_YELLOW:-}Use this for paid themes like Nebula — these require a legitimate purchase.${C_RESET:-}"
    echo ""

    local bp_bin
    bp_bin="$(_frosty_blueprint_cmd)"
    if [[ -z "$bp_bin" ]]; then
        _frosty_fail "Blueprint isn't installed — install it first (option 1)"
        return 1
    fi

    echo "  How do you want to get the file onto this server?"
    echo "  [1] It's already here — I'll give you the path"
    echo "  [2] Upload it via browser (no SCP needed)"
    read -rp "  Choice [1-2]: " transfer_choice

    local bp_path=""
    case "$transfer_choice" in
        1) read -rp "  Full path to the .blueprint file on this server: " bp_path ;;
        2)
            bp_path="$(blueprint_receive_upload)"
            [[ -z "$bp_path" ]] && { _frosty_fail "No file was received"; return 1; }
            ;;
        *) _frosty_fail "Invalid choice"; return 1 ;;
    esac

    if [[ ! -f "$bp_path" ]]; then
        _frosty_fail "File not found: ${bp_path}"
        return 1
    fi

    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"
    ( cd "$panel_dir" && timeout 120 "$bp_bin" -install "$bp_path" 2>&1 | tee /tmp/frosty_blueprint_install_file.log )
    local rc=${PIPESTATUS[0]}

    if [[ $rc -eq 0 ]]; then
        _frosty_ok "Installed from ${bp_path}"
    else
        _frosty_fail "Install failed — see /tmp/frosty_blueprint_install_file.log"
        return 1
    fi
}

blueprint_receive_upload() {
    local upload_dir="/tmp/frosty_uploads"
    mkdir -p "$upload_dir"
    rm -f "${upload_dir}"/*.blueprint 2>/dev/null

    local port=8899
    while ss -ltn 2>/dev/null | grep -q ":${port} "; do
        port=$((port + 1))
    done

    local pubip="${FROSTY_PUBLIC_IP:-$(curl -s --max-time 5 ifconfig.me 2>/dev/null)}"

    cat > /tmp/frosty_upload_server.py << 'PYEOF'
import http.server, sys, os, re

UPLOAD_DIR = sys.argv[2] if len(sys.argv) > 2 else "/tmp/frosty_uploads"

PAGE = """<!DOCTYPE html><html><head><title>Frosty.exe - File Upload</title>
<style>body{font-family:sans-serif;background:#0b1220;color:#eee;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0}
.box{background:#151f30;padding:2rem 3rem;border-radius:12px;text-align:center}
input[type=file]{margin:1rem 0}button{background:#38bdf8;border:none;padding:0.6rem 1.4rem;
border-radius:6px;font-weight:bold;cursor:pointer}</style></head>
<body><div class="box"><h2>Upload .blueprint file</h2>
<form method="POST" enctype="multipart/form-data">
<input type="file" name="file" accept=".blueprint,.zip"><br>
<button type="submit">Upload</button></form></div></body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(PAGE.encode())

    def do_POST(self):
        content_type = self.headers.get("Content-Type", "")
        m = re.search(r"boundary=(.+)", content_type)
        if not m:
            self.send_response(400)
            self.end_headers()
            return
        boundary = m.group(1).strip('"').encode()
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        parts = body.split(b"--" + boundary)
        filename = None
        filedata = None
        for part in parts:
            if b'name="file"' not in part:
                continue
            fm = re.search(rb'filename="([^"]+)"', part)
            if not fm:
                continue
            filename = fm.group(1).decode(errors="replace")
            idx = part.find(b"\r\n\r\n")
            if idx == -1:
                continue
            filedata = part[idx + 4:]
            if filedata.endswith(b"\r\n"):
                filedata = filedata[:-2]
            break

        if filename and filedata is not None:
            fname = os.path.basename(filename)
            dest = os.path.join(UPLOAD_DIR, fname)
            with open(dest, "wb") as f:
                f.write(filedata)
            with open(os.path.join(UPLOAD_DIR, ".received"), "w") as f:
                f.write(dest)
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<h2>Uploaded. You can close this tab.</h2>")
        else:
            self.send_response(400)
            self.end_headers()

    def log_message(self, *a):
        pass

http.server.HTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
PYEOF

    python3 /tmp/frosty_upload_server.py "$port" "$upload_dir" >/tmp/frosty_upload_server.log 2>&1 &
    local server_pid=$!

    echo "" >&2
    echo -e "    ${C_YELLOW:-}Open this link in a browser and upload the file:${C_RESET:-}" >&2
    echo -e "    ${C_CYAN:-}http://${pubip}:${port}${C_RESET:-}" >&2
    echo -n "    Waiting for upload (up to 5 minutes)" >&2

    local waited=0
    while [[ ${waited} -lt 300 ]]; do
        [[ -f "${upload_dir}/.received" ]] && break
        echo -n "." >&2
        sleep 2
        waited=$((waited + 2))
    done
    echo "" >&2

    kill "$server_pid" 2>/dev/null

    if [[ -f "${upload_dir}/.received" ]]; then
        local received_path
        received_path="$(cat "${upload_dir}/.received")"
        rm -f "${upload_dir}/.received"
        echo -e "    ${C_GREEN:-}Received: ${received_path}${C_RESET:-}" >&2
        echo "$received_path"
    else
        echo -e "    ${C_RED:-}No upload received within 5 minutes.${C_RESET:-}" >&2
        echo ""
    fi
}

blueprint_remove_extension() {
    echo ""
    local bp_bin
    bp_bin="$(_frosty_blueprint_cmd)"
    if [[ -z "$bp_bin" ]]; then
        _frosty_fail "Blueprint isn't installed"
        return 1
    fi
    "$bp_bin" -list 2>&1
    echo ""
    read -rp "  Extension identifier to remove: " ext_id
    [[ -z "$ext_id" ]] && { _frosty_fail "Identifier required"; return 1; }

    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"
    ( cd "$panel_dir" && "$bp_bin" -remove "$ext_id" 2>&1 | tee /tmp/frosty_blueprint_remove.log )
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        _frosty_ok "'${ext_id}' removed"
    else
        _frosty_fail "Remove failed — see /tmp/frosty_blueprint_remove.log"
        return 1
    fi
}

show_themes_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}   ${C_ICE}${C_BOLD}❄  T H E M E S  &  E X T E N S I O N S  ❄${C_RESET}  ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    if blueprint_installed; then
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}  Blueprint: ${C_GREEN}installed${C_RESET}                              ${C_FROST}${C_BOLD}║${C_RESET}"
    else
        echo -e "${C_FROST}${C_BOLD}║${C_RESET}  Blueprint: ${C_RED}not installed${C_RESET}                          ${C_FROST}${C_BOLD}║${C_RESET}"
    fi
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Install Blueprint Framework${C_RESET}              ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Install Recolor (free theme)${C_RESET}             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[3]${C_RESET} ${C_WHITE}Install Nebula (requires purchase)${C_RESET}       ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[4]${C_RESET} ${C_WHITE}Install Other (by name/catalog)${C_RESET}          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_ICE}[5]${C_RESET} ${C_WHITE}Install From Purchased .blueprint File${C_RESET}   ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_GREEN}[6]${C_RESET} ${C_WHITE}List Installed${C_RESET}                           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[7]${C_RESET} ${C_WHITE}Remove Extension${C_RESET}                         ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[8]${C_RESET} ${C_WHITE}Back${C_RESET}                                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-8]: " theme_choice

    case "$theme_choice" in
        1) install_blueprint ;;
        2) blueprint_install_open_extension "recolor" ;;
        3)
            echo ""
            echo -e "${C_YELLOW:-}Nebula is a paid theme sold on BuiltByBit — no public download exists.${C_RESET:-}"
            echo -e "${C_YELLOW:-}Buy it at: https://builtbybit.com/resources/nebula.32442/${C_RESET:-}"
            echo -e "${C_YELLOW:-}then use option [5] with the downloaded .blueprint file.${C_RESET:-}"
            ;;
        4)
            read -rp "  Extension/theme identifier: " custom_ext
            [[ -n "$custom_ext" ]] && blueprint_install_open_extension "$custom_ext"
            ;;
        5) blueprint_install_from_file ;;
        6) blueprint_list_installed ;;
        7) blueprint_remove_extension ;;
        8) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_themes_submenu
}

run_themes_flow() {
    show_themes_submenu
}
