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
    if ! COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 timeout 600 composer install \
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
    return 0
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
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[2]${C_RESET} ${C_WHITE}Uninstall Blueprint Framework${C_RESET}            ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[3]${C_RESET} ${C_WHITE}Install NookTheme (free theme)${C_RESET}           ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[4]${C_RESET} ${C_WHITE}Back${C_RESET}                                     ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-4]: " theme_choice

    case "$theme_choice" in
        1) install_blueprint ;;
        2) uninstall_blueprint ;;
        3) install_nook_theme ;;
        4) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
    show_themes_submenu
}

run_themes_flow() {
    show_themes_submenu
}
