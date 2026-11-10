#!/usr/bin/env bash
set -uo pipefail

FROSTY_BLUEPRINT_RC="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}/.blueprintrc"
FROSTY_BLUEPRINT_BIN="/usr/local/bin/blueprint"

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
        file "${panel_dir}/release.zip" 2>/dev/null | sed 's/^/    /'
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
        return 1
    fi
}

# Fully removes Blueprint: its CLI, its data directory, its config file,
# and — critically — the hooks it wrote into AppServiceProvider.php,
# which is what actually breaks the panel if left dangling after a
# partial or corrupted Blueprint state (references to files that no
# longer exist cause a hard 500 on every request).
uninstall_blueprint() {
    echo ""
    echo -e "${C_CYAN:-}== Uninstalling Blueprint Framework ==${C_RESET:-}"
    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"

    if [[ -f "${panel_dir}/app/Providers/AppServiceProvider.php" ]]; then
        cp "${panel_dir}/app/Providers/AppServiceProvider.php" "/tmp/AppServiceProvider.php.bak"
        sed -i '/Blueprint/d' "${panel_dir}/app/Providers/AppServiceProvider.php"
        _frosty_ok "Removed Blueprint hooks from AppServiceProvider.php (backup: /tmp/AppServiceProvider.php.bak)"
    fi

    rm -rf "${panel_dir}/app/Providers/Blueprint"
    rm -rf "${panel_dir}/.blueprint"
    rm -f "${panel_dir}/.blueprintrc"
    rm -f "$FROSTY_BLUEPRINT_BIN"
    _frosty_ok "Removed Blueprint files and data directory"

    echo "    Rebuilding autoloader and clearing caches..."
    ( cd "$panel_dir" && composer dump-autoload >/tmp/frosty_blueprint_uninstall.log 2>&1 )
    ( cd "$panel_dir" && "php${FROSTY_PHP_VERSION:-8.3}" artisan config:clear >>/tmp/frosty_blueprint_uninstall.log 2>&1 )
    ( cd "$panel_dir" && "php${FROSTY_PHP_VERSION:-8.3}" artisan cache:clear >>/tmp/frosty_blueprint_uninstall.log 2>&1 )

    local version_check
    version_check="$(cd "$panel_dir" && "php${FROSTY_PHP_VERSION:-8.3}" artisan --version 2>&1)"
    if echo "$version_check" | grep -q "^Laravel Framework"; then
        _frosty_ok "Panel boots cleanly: $version_check"
    else
        _frosty_fail "Panel still fails to boot after removal — see /tmp/frosty_blueprint_uninstall.log"
        echo "$version_check" | head -10 | sed 's/^/    /'
    fi
}

# Installs NookTheme (free, open-source: github.com/Nookure/NookTheme)
# directly from its official release. Hardened version of a community
# install script: adds timeouts (the exact hang risk this project has
# hit repeatedly), checks each step before continuing, and guarantees
# the panel goes back "up" even on failure — the original always ran
# `php artisan up` unconditionally, which would expose a half-broken
# panel to real users if a step failed silently.
install_nook_theme() {
    echo ""
    echo -e "${C_CYAN:-}== Installing NookTheme ==${C_RESET:-}"
    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"

    if [[ ! -f "${panel_dir}/artisan" ]]; then
        _frosty_fail "Panel not found at ${panel_dir} — install the Panel first"
        return 1
    fi

    cd "$panel_dir" || return 1
    "php${FROSTY_PHP_VERSION:-8.3}" artisan down >/dev/null 2>&1

    echo "    Downloading NookTheme..."
    rm -f /tmp/frosty_nooktheme.tar.gz
    if ! timeout 120 curl -fL -o /tmp/frosty_nooktheme.tar.gz \
        "https://github.com/Nookure/NookTheme/releases/latest/download/panel.tar.gz" \
        >/tmp/frosty_nooktheme_download.log 2>&1; then
        _frosty_fail "Download failed or timed out — see /tmp/frosty_nooktheme_download.log"
        "php${FROSTY_PHP_VERSION:-8.3}" artisan up >/dev/null 2>&1
        return 1
    fi

    echo "    Extracting over the panel..."
    if ! tar -xzf /tmp/frosty_nooktheme.tar.gz -C "$panel_dir" >/tmp/frosty_nooktheme_extract.log 2>&1; then
        _frosty_fail "Extraction failed — see /tmp/frosty_nooktheme_extract.log"
        "php${FROSTY_PHP_VERSION:-8.3}" artisan up >/dev/null 2>&1
        return 1
    fi
    rm -f /tmp/frosty_nooktheme.tar.gz
    chmod -R 755 storage bootstrap/cache 2>/dev/null

    echo "    Running composer install (this can take a few minutes)..."
    if ! COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 timeout 600 "php${FROSTY_PHP_VERSION:-8.3}" /usr/local/bin/composer install \
        --no-dev --optimize-autoloader --no-interaction \
        >/tmp/frosty_nooktheme_composer.log 2>&1; then
        _frosty_fail "composer install failed or timed out — see /tmp/frosty_nooktheme_composer.log"
        _frosty_warn "Panel left in maintenance mode ('php artisan up' NOT run) — fix the composer error first, then run: php${FROSTY_PHP_VERSION:-8.3} artisan up"
        return 1
    fi

    "php${FROSTY_PHP_VERSION:-8.3}" artisan view:clear >/dev/null 2>&1
    "php${FROSTY_PHP_VERSION:-8.3}" artisan config:clear >/dev/null 2>&1

    echo "    Running database migrations..."
    if ! "php${FROSTY_PHP_VERSION:-8.3}" artisan migrate --seed --force >/tmp/frosty_nooktheme_migrate.log 2>&1; then
        _frosty_fail "Migration failed — see /tmp/frosty_nooktheme_migrate.log"
        _frosty_warn "Panel left in maintenance mode — review the migration error before bringing it back up"
        return 1
    fi

    chown -R www-data:www-data "$panel_dir"
    "php${FROSTY_PHP_VERSION:-8.3}" artisan queue:restart >/dev/null 2>&1
    "php${FROSTY_PHP_VERSION:-8.3}" artisan up >/dev/null 2>&1

    _frosty_ok "NookTheme installed and panel is back up"
    echo ""
    echo -e "${C_CYAN:-}    ─────────────────────────────────────${C_RESET:-}"
    echo -e "${C_WHITE:-}    Theme:${C_RESET:-} NookTheme"
    echo -e "${C_WHITE:-}    Theme created by:${C_RESET:-} Nookure (github.com/Nookure/NookTheme)"
    echo -e "${C_WHITE:-}    Install script by:${C_RESET:-} Jishnu"
    echo -e "${C_YELLOW:-}    Special thanks to both for making this available.${C_RESET:-}"
    echo -e "${C_CYAN:-}    ─────────────────────────────────────${C_RESET:-}"
    return 0
}

declare -F _frosty_menu_row >/dev/null 2>&1 || _frosty_menu_row() {
    local color="$1" label="$2" text="$3" pad
    pad=$(( 45 - ${#label} - ${#text} )); (( pad < 1 )) && pad=1
    printf '%b\n' "${C_FROST}${C_BOLD}║${C_RESET}  ${color}${label}${C_RESET} ${C_WHITE}${text}${C_RESET}$(printf '%*s' "$pad" '')${C_FROST}${C_BOLD}║${C_RESET}"
}

_frosty_panel_dir() { echo "${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"; }

# Panel present + Blueprint present (offers to install it).
_frosty_bp_ready() {
    local panel_dir; panel_dir="$(_frosty_panel_dir)"
    if [[ ! -f "${panel_dir}/artisan" ]]; then
        _frosty_fail "Panel not found at ${panel_dir} — install the Panel first"
        return 1
    fi
    if ! blueprint_installed; then
        _frosty_warn "Blueprint is required for this and is not installed."
        read -rp "  Install Blueprint now? [Y/n]: " bp_ans
        [[ "${bp_ans:-Y}" =~ ^[Yy] ]] || return 1
        install_blueprint || return 1
    fi
    return 0
}

# Installs a local .blueprint file. $1 = path, $2 = identifier (must equal the file's identifier).
_frosty_bp_install_file() {
    local src="$1" id="$2" panel_dir bp_bin log rc
    panel_dir="$(_frosty_panel_dir)"
    bp_bin="$(_frosty_blueprint_cmd)"
    log="/tmp/frosty_bp_${id}.log"

    [[ -f "$src" ]] || { _frosty_fail "File not found: $src"; return 1; }
    if ! [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]]; then _frosty_fail "Invalid extension identifier: '$id'"; return 1; fi
    if ! unzip -tq "$src" >/dev/null 2>&1; then
        _frosty_fail "Not a valid .blueprint file (it must be a zip archive)"
        return 1
    fi

    cp -f "$src" "${panel_dir}/${id}.blueprint"
    chown www-data:www-data "${panel_dir}/${id}.blueprint" 2>/dev/null
    echo "    Running: blueprint -install ${id}"
    ( cd "$panel_dir" && set +o pipefail; yes y 2>/dev/null | "$bp_bin" -install "$id" ) >"$log" 2>&1
    rc=$?
    rm -f "${panel_dir}/${id}.blueprint"

    if [[ $rc -ne 0 ]]; then
        _frosty_fail "Blueprint could not install '${id}' — see ${log}"
        tail -n 8 "$log" | sed 's/^/      /'
        return 1
    fi
    _frosty_ok "'${id}' installed (log: ${log})"
    return 0
}

# $1 = display name, $2 = direct .blueprint URL, $3 = identifier
_frosty_bp_install_release() {
    local name="$1" url="$2" id="$3" tmp
    echo ""
    echo -e "${C_CYAN:-}== Installing ${name} ==${C_RESET:-}"
    _frosty_bp_ready || return 1
    tmp="$(mktemp /tmp/frosty_bp_dl_XXXXXX)"
    echo "    Downloading ${name}..."
    if ! timeout 180 curl -fL --retry 2 -o "$tmp" "$url" >"/tmp/frosty_bp_${id}_download.log" 2>&1; then
        rm -f "$tmp"
        _frosty_fail "Download failed — see /tmp/frosty_bp_${id}_download.log"
        return 1
    fi
    _frosty_bp_install_file "$tmp" "$id"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

install_darkenate_theme() {
    _frosty_bp_install_release "Darkenate (dark theme)" \
        "https://github.com/blueprint-community/extension-darkenate/releases/latest/download/darkenate.blueprint" "darkenate"
}

install_abyss_purple_theme() {
    _frosty_bp_install_release "Abyss Purple (dark/purple theme)" \
        "https://github.com/fernsehheft/Abyss-Purple/releases/latest/download/abysspurple.blueprint" "abysspurple"
}

install_modrinth_plugin_installer() {
    _frosty_bp_install_release "Modrinth Browser (Minecraft plugin installer)" \
        "https://github.com/fernsehheft/BluePrint-Free-Plugins-Extension/releases/latest/download/modrinthbrowser.blueprint" "modrinthbrowser"
}

# Recolor ships as source only (no release file): we package the repo into a .blueprint ourselves.
install_recolor_theme() {
    echo ""
    echo -e "${C_CYAN:-}== Installing Recolor ==${C_RESET:-}"
    _frosty_bp_ready || return 1
    if ! command -v zip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y zip >/dev/null 2>&1 || { _frosty_fail "Could not install 'zip'"; return 1; }
    fi
    local work; work="$(mktemp -d /tmp/frosty_recolor_XXXXXX)"
    echo "    Downloading Recolor source..."
    if ! GIT_TERMINAL_PROMPT=0 timeout 90 git clone --depth 1 https://github.com/sp11rum/recolor.git "${work}/src" >/tmp/frosty_recolor_clone.log 2>&1; then
        rm -rf "$work"
        _frosty_fail "Clone failed — see /tmp/frosty_recolor_clone.log"
        return 1
    fi
    local target
    target="$(grep -m1 'target:' "${work}/src/conf.yml" 2>/dev/null | sed 's/.*target:[[:space:]]*//; s/"//g')"
    _frosty_warn "Recolor was built for Blueprint '${target:-unknown}' (it is old and unmaintained) — it may not work with the newest Blueprint."
    ( cd "${work}/src" && zip -qr "${work}/recolor.blueprint" . -x '.git/*' )
    _frosty_bp_install_file "${work}/recolor.blueprint" "recolor"
    local rc=$?
    rm -rf "$work"
    return $rc
}

install_blueprint_from_url() {
    echo ""
    echo -e "${C_CYAN:-}== Install Extension From URL ==${C_RESET:-}"
    _frosty_bp_ready || return 1
    read -rp "  Direct URL to a .blueprint file: " bp_url
    bp_url="${bp_url//[[:space:]]/}"
    [[ "$bp_url" =~ ^https://.+\.blueprint(\?.*)?$ ]] || { _frosty_fail "Need an https:// URL ending in .blueprint"; return 1; }
    local file id tmp
    file="$(basename "${bp_url%%\?*}")"; id="${file%.blueprint}"
    read -rp "  Extension identifier [${id}]: " in_id
    id="${in_id:-$id}"
    tmp="$(mktemp /tmp/frosty_bp_dl_XXXXXX)"
    if ! timeout 180 curl -fL --retry 2 -o "$tmp" "$bp_url" >/tmp/frosty_bp_url_download.log 2>&1; then
        rm -f "$tmp"; _frosty_fail "Download failed — see /tmp/frosty_bp_url_download.log"; return 1
    fi
    _frosty_bp_install_file "$tmp" "$id"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

install_blueprint_from_file() {
    echo ""
    echo -e "${C_CYAN:-}== Install Extension From a File ==${C_RESET:-}"
    echo "    Upload the .blueprint file to this server first (scp/SFTP), then enter its path."
    _frosty_bp_ready || return 1
    read -rp "  Path to the .blueprint file: " bp_path
    bp_path="${bp_path/#\~/$HOME}"
    [[ -f "$bp_path" ]] || { _frosty_fail "File not found: $bp_path"; return 1; }
    local id; id="$(basename "$bp_path")"; id="${id%.blueprint}"
    read -rp "  Extension identifier [${id}]: " in_id
    _frosty_bp_install_file "$bp_path" "${in_id:-$id}"
}

list_blueprint_extensions() {
    echo ""
    echo -e "${C_CYAN:-}== Installed Blueprint Extensions ==${C_RESET:-}"
    local panel_dir; panel_dir="$(_frosty_panel_dir)"
    if ! blueprint_installed; then _frosty_warn "Blueprint is not installed"; return 1; fi
    echo "    Blueprint: $("$(_frosty_blueprint_cmd)" -v 2>/dev/null | head -1)"
    if [[ -d "${panel_dir}/.blueprint/extensions" ]] && [[ -n "$(ls -A "${panel_dir}/.blueprint/extensions" 2>/dev/null)" ]]; then
        ls -1 "${panel_dir}/.blueprint/extensions" | sed 's/^/      - /'
    else
        echo "      (none)"
    fi
}

remove_blueprint_extension() {
    echo ""
    echo -e "${C_CYAN:-}== Remove Extension ==${C_RESET:-}"
    list_blueprint_extensions || return 1
    read -rp "  Identifier to remove: " rm_id
    rm_id="${rm_id//[[:space:]]/}"
    [[ "$rm_id" =~ ^[A-Za-z0-9_-]+$ ]] || { _frosty_fail "Invalid identifier"; return 1; }
    read -rp "  Remove '${rm_id}'? [y/N]: " rm_ok
    [[ "$rm_ok" =~ ^[Yy] ]] || { echo "Cancelled."; return 1; }
    local panel_dir bp_bin; panel_dir="$(_frosty_panel_dir)"; bp_bin="$(_frosty_blueprint_cmd)"
    ( cd "$panel_dir" && set +o pipefail; yes y 2>/dev/null | "$bp_bin" -remove "$rm_id" ) >"/tmp/frosty_bp_remove_${rm_id}.log" 2>&1
    if [[ $? -eq 0 ]]; then _frosty_ok "'${rm_id}' removed"; else
        _frosty_fail "Removal failed — see /tmp/frosty_bp_remove_${rm_id}.log"; return 1; fi
}

_frosty_ensure_node_yarn() {
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d v)" -lt 18 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git gnupg unzip wget zip >/tmp/frosty_node_deps.log 2>&1
        mkdir -p /etc/apt/keyrings
        timeout 60 curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>/dev/null | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/frosty_node_install.log 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >>/tmp/frosty_node_install.log 2>&1
    fi
    command -v node >/dev/null 2>&1 || { _frosty_fail "Node.js install failed — see /tmp/frosty_node_install.log"; return 1; }
    command -v yarn >/dev/null 2>&1 || npm i -g yarn >/tmp/frosty_yarn_install.log 2>&1
    command -v yarn >/dev/null 2>&1 || { _frosty_fail "Yarn install failed — see /tmp/frosty_yarn_install.log"; return 1; }
    return 0
}

# NEOBRUTALIS is a full copy of the panel (a fork), not an extension: it is laid over the
# existing panel files, dependencies are installed and the frontend is rebuilt.
install_neobrutalis_theme() {
    echo ""
    echo -e "${C_CYAN:-}== Installing NEOBRUTALIS-Pterodactyl (full panel overlay) ==${C_RESET:-}"
    local panel_dir php_bin work backup
    panel_dir="$(_frosty_panel_dir)"; php_bin="php${FROSTY_PHP_VERSION:-8.3}"
    if [[ ! -f "${panel_dir}/artisan" ]]; then _frosty_fail "Panel not found at ${panel_dir}"; return 1; fi

    echo -e "${C_YELLOW:-}    This REPLACES core panel files with the NEOBRUTALIS fork (panel 1.15.x) and rebuilds the frontend.${C_RESET:-}"
    echo "    A full backup of the panel folder is made first. Your .env and storage/ are not touched."
    echo "    Its optional e-mail features are preconfigured for the author's own domain — ignore them unless you set up Resend."
    read -rp "  Type YES to continue: " ans
    [[ "$ans" == "YES" ]] || { echo "Cancelled."; return 1; }

    backup="/var/backups/pterodactyl-before-neobrutalis-$(date +%F-%H%M).tar.gz"
    mkdir -p /var/backups
    echo "    Backing up panel to ${backup} ..."
    if ! tar -czf "$backup" -C "$(dirname "$panel_dir")" "$(basename "$panel_dir")" 2>/tmp/frosty_neo_backup.log; then
        _frosty_fail "Backup failed — see /tmp/frosty_neo_backup.log (nothing was changed)"; return 1
    fi
    _frosty_ok "Backup created"

    _frosty_ensure_node_yarn || return 1

    work="$(mktemp -d /tmp/frosty_neo_XXXXXX)"
    echo "    Downloading NEOBRUTALIS..."
    if ! GIT_TERMINAL_PROMPT=0 timeout 180 git clone --depth 1 https://github.com/firllyfikaa/NEOBRUTALIS-Pterodactyl.git "${work}/src" >/tmp/frosty_neo_clone.log 2>&1; then
        rm -rf "$work"; _frosty_fail "Clone failed — see /tmp/frosty_neo_clone.log (nothing was changed)"; return 1
    fi

    cd "$panel_dir" || return 1
    "$php_bin" artisan down >/dev/null 2>&1
    echo "    Copying theme files over the panel..."
    if ! tar -C "${work}/src" --exclude=.git --exclude=.github --exclude=docs --exclude=node_modules \
         --exclude=.env --exclude='.env.*' -cf - . | tar -C "$panel_dir" -xf -; then
        rm -rf "$work"; _frosty_fail "Copy failed — restore with: tar -xzf ${backup} -C $(dirname "$panel_dir")"
        "$php_bin" artisan up >/dev/null 2>&1; return 1
    fi
    rm -rf "$work"

    echo "    composer install..."
    if ! COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 timeout 900 "$php_bin" /usr/local/bin/composer install \
         --no-dev --optimize-autoloader --no-interaction >/tmp/frosty_neo_composer.log 2>&1; then
        _frosty_fail "composer failed — see /tmp/frosty_neo_composer.log (panel left in maintenance mode; backup: ${backup})"; return 1
    fi
    echo "    Database migrations..."
    if ! "$php_bin" artisan migrate --seed --force >/tmp/frosty_neo_migrate.log 2>&1; then
        _frosty_fail "Migration failed — see /tmp/frosty_neo_migrate.log (panel left in maintenance mode; backup: ${backup})"; return 1
    fi
    echo "    Building frontend (this can take 5-15 minutes)..."
    if ! ( timeout 1800 yarn install >/tmp/frosty_neo_yarn.log 2>&1 \
           && NODE_OPTIONS=--openssl-legacy-provider timeout 1800 yarn build:production >/tmp/frosty_neo_build.log 2>&1 ) \
       && ! ( timeout 1800 yarn build:production >/tmp/frosty_neo_build.log 2>&1 ); then
        _frosty_fail "Frontend build failed — see /tmp/frosty_neo_yarn.log and /tmp/frosty_neo_build.log (panel left in maintenance mode; backup: ${backup})"
        return 1
    fi

    "$php_bin" artisan optimize:clear >/dev/null 2>&1
    chown -R www-data:www-data "$panel_dir"
    "$php_bin" artisan queue:restart >/dev/null 2>&1
    "$php_bin" artisan up >/dev/null 2>&1
    _frosty_ok "NEOBRUTALIS installed and the panel is back up (hard-refresh your browser)"
    echo "    Credit: github.com/firllyfikaa/NEOBRUTALIS-Pterodactyl"
    echo "    Roll back any time: tar -xzf ${backup} -C $(dirname "$panel_dir")"
}

show_extension_catalog() {
    echo ""
    echo -e "${C_CYAN:-}== Extensions & Addons — where to get them ==${C_RESET:-}"
    echo -e "${C_GREEN:-}  One-click here (free, verified source):${C_RESET:-}"
    echo "    Plugin Installer ........ Modrinth Browser   (Extensions menu [1])"
    echo "    Themes .................. NookTheme, Darkenate, Abyss Purple, Recolor, NEOBRUTALIS"
    echo ""
    echo -e "${C_YELLOW:-}  Not bundled (paid or no stable free release found):${C_RESET:-}"
    echo "    Subdomain Manager, Modpack Installer, Nebula, Noobee, IceMinecraftTheme, ..."
    echo "    -> buy/download from the creator (BuiltByBit / blueprint.zip / their GitHub)."
    echo "    -> if you get a .blueprint file: Extensions menu -> Install from file (or URL)."
    echo "    -> if it is a zip/tar overlay, follow the creator's own instructions."
    echo ""
    echo "  Also useful categories (search blueprint.zip/browse):"
    echo "    Server Importer, Advanced Backups, Server Expiry, Announcements, Discord Alerts,"
    echo "    Audit Logs, Monitoring, Database tools, Player Manager, Server Notes,"
    echo "    Custom Buttons, Auto-Sleep."
    echo ""
    echo "  Always back up the panel before installing paid/unknown addons."
}

show_extensions_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}$(_frosty_center "${C_ICE}${C_BOLD}E X T E N S I O N S   &   A D D O N S${C_RESET}" 48)${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠════════════════════════════════════════════════╣${C_RESET}"
    _frosty_menu_row "$C_CYAN"   "[1]" "Plugin Installer (Modrinth, free)"
    _frosty_menu_row "$C_PURPLE" "[2]" "Install extension from URL (.blueprint)"
    _frosty_menu_row "$C_PURPLE" "[3]" "Install extension from file (.blueprint)"
    _frosty_menu_row "$C_ICE"    "[4]" "List installed extensions"
    _frosty_menu_row "$C_RED"    "[5]" "Remove an extension"
    _frosty_menu_row "$C_YELLOW" "[6]" "Catalog: where to get other addons"
    _frosty_menu_row "$C_BLUE"   "[7]" "Back"
    echo -e "${C_FROST}${C_BOLD}╚════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-7]: " ext_choice

    case "$ext_choice" in
        1) install_modrinth_plugin_installer ;;
        2) install_blueprint_from_url ;;
        3) install_blueprint_from_file ;;
        4) list_blueprint_extensions ;;
        5) remove_blueprint_extension ;;
        6) show_extension_catalog ;;
        7) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_extensions_submenu
}

show_themes_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}$(_frosty_center "${C_ICE}${C_BOLD}❄  T H E M E S  &  E X T E N S I O N S  ❄${C_RESET}" 48)${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠════════════════════════════════════════════════╣${C_RESET}"
    if blueprint_installed; then
        _frosty_menu_row "$C_GREEN" "Blueprint:" "installed"
    else
        _frosty_menu_row "$C_RED" "Blueprint:" "not installed"
    fi
    _frosty_menu_row "$C_CYAN"   "[1]" "Install Blueprint Framework"
    _frosty_menu_row "$C_RED"    "[2]" "Uninstall Blueprint Framework"
    _frosty_menu_row "$C_PURPLE" "[3]" "NookTheme (sidebar theme)"
    _frosty_menu_row "$C_PURPLE" "[4]" "Darkenate (dark, Blueprint)"
    _frosty_menu_row "$C_PURPLE" "[5]" "Abyss Purple (dark/purple, Blueprint)"
    _frosty_menu_row "$C_PURPLE" "[6]" "Recolor (dark, Blueprint)"
    _frosty_menu_row "$C_PURPLE" "[7]" "NEOBRUTALIS (full overlay, rebuilds)"
    _frosty_menu_row "$C_CYAN"   "[8]" "Extensions & Addons >"
    _frosty_menu_row "$C_BLUE"   "[9]" "Back"
    echo -e "${C_FROST}${C_BOLD}╚════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-9]: " theme_choice

    case "$theme_choice" in
        1) install_blueprint ;;
        2) uninstall_blueprint ;;
        3) install_nook_theme ;;
        4) install_darkenate_theme ;;
        5) install_abyss_purple_theme ;;
        6) install_recolor_theme ;;
        7) install_neobrutalis_theme ;;
        8) show_extensions_submenu; show_themes_submenu; return 0 ;;
        9) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_themes_submenu
}

run_themes_flow() {
    show_themes_submenu
}
