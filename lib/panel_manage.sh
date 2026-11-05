#!/usr/bin/env bash
set -uo pipefail

panel_add_user() {
    echo ""
    echo "== Add New Panel User =="
    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }
    php"${FROSTY_PHP_VERSION:-8.3}" artisan p:user:make
}

panel_update() {
    echo ""
    echo "== Updating Pterodactyl Panel =="
    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }

    local backup_dir="/var/backups/frosty/panel_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "    Backing up current Panel to $backup_dir ..."
    cp -a "${FROSTY_PANEL_DIR}/.env" "$backup_dir/.env" 2>/dev/null
    if ! tar -czf "$backup_dir/panel_backup.tar.gz" --exclude=node_modules -C "${FROSTY_PANEL_DIR}" . 2>/tmp/frosty_update_backup.log; then
        _frosty_fail "Backup failed — see /tmp/frosty_update_backup.log. Aborting update."
        return 1
    fi
    _frosty_ok "Backup created at $backup_dir"

    php"${FROSTY_PHP_VERSION:-8.3}" artisan down 2>/dev/null

    echo "    Downloading latest release..."
    if curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz >/tmp/frosty_update_download.log 2>&1; then
        tar -xzf panel.tar.gz >/tmp/frosty_update_extract.log 2>&1
        rm -f panel.tar.gz
        chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null
        _frosty_ok "Latest Panel files extracted"
    else
        _frosty_fail "Update download failed — see /tmp/frosty_update_download.log"
        php"${FROSTY_PHP_VERSION:-8.3}" artisan up 2>/dev/null
        return 1
    fi

    echo "    Installing dependencies..."
    if COMPOSER_ALLOW_SUPERUSER=1 "php${FROSTY_PHP_VERSION:-8.3}" /usr/local/bin/composer install --no-dev --optimize-autoloader --no-interaction >/tmp/frosty_update_composer.log 2>&1; then
        _frosty_ok "Composer dependencies updated"
    else
        _frosty_fail "composer install failed during update — see /tmp/frosty_update_composer.log"
        php"${FROSTY_PHP_VERSION:-8.3}" artisan up 2>/dev/null
        return 1
    fi

    echo "    Running migrations..."
    if ! php"${FROSTY_PHP_VERSION:-8.3}" artisan migrate --seed --force >/tmp/frosty_update_migrate.log 2>&1; then
        _frosty_fail "Migration failed — see /tmp/frosty_update_migrate.log (panel left in maintenance mode)"
        return 1
    fi
    php"${FROSTY_PHP_VERSION:-8.3}" artisan view:clear >/dev/null 2>&1
    php"${FROSTY_PHP_VERSION:-8.3}" artisan config:clear >/dev/null 2>&1

    chown -R www-data:www-data "${FROSTY_PANEL_DIR}" 2>/dev/null

    php"${FROSTY_PHP_VERSION:-8.3}" artisan queue:restart >/dev/null 2>&1
    php"${FROSTY_PHP_VERSION:-8.3}" artisan up 2>/dev/null

    if [[ -d /run/systemd/system ]]; then
        systemctl restart nginx "php${FROSTY_PHP_VERSION:-8.3}-fpm" >/dev/null 2>&1
    fi

    _frosty_ok "Panel update complete"
    return 0
}

panel_uninstall() {
    echo ""
    echo -e "${C_RED}== Uninstall Panel ==${C_RESET}"
    echo -e "${C_YELLOW}This will permanently delete:${C_RESET}"
    echo "    - ${FROSTY_PANEL_DIR}"
    echo "    - The 'panel' database"
    echo "    - nginx site config for Pterodactyl"
    echo ""
    read -rp "  Type UNINSTALL to confirm: " confirm

    if [[ "$confirm" != "UNINSTALL" ]]; then
        echo "Cancelled."
        return 1
    fi

    local backup_dir="/var/backups/frosty/panel_uninstall_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${FROSTY_PANEL_DIR}/.env" "$backup_dir/.env" 2>/dev/null
    echo "    .env backed up to $backup_dir before removal"

    if [[ -d /run/systemd/system ]]; then
        systemctl disable --now pteroq >/dev/null 2>&1
        rm -f /etc/systemd/system/pteroq.service
        systemctl daemon-reload >/dev/null 2>&1
    else
        pm2 delete pteroq >/dev/null 2>&1
        pm2 save >/dev/null 2>&1
    fi
    (crontab -l 2>/dev/null | grep -v "artisan schedule:run") | crontab - 2>/dev/null || true

    rm -rf "${FROSTY_PANEL_DIR}"
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf

    mysql -u root -e "DROP DATABASE IF EXISTS panel; DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';" 2>/dev/null

    if [[ -d /run/systemd/system ]]; then
        systemctl restart nginx >/dev/null 2>&1
    else
        pm2 restart nginx >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1
    fi

    _frosty_ok "Panel uninstalled"
    return 0
}

# Fixes "Generate Token" (and other AJAX) failing when the panel is served
# through a Cloudflare Tunnel / HTTPS proxy: APP_URL must be the public https
# URL and the panel must trust the proxy's X-Forwarded-* headers.
panel_apply_proxy_fix() {
    echo ""
    echo "== Panel HTTPS / Proxy Fix (Cloudflare Tunnel) =="
    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }
    local php_bin="php${FROSTY_PHP_VERSION:-8.3}"

    local cur_url new_url
    cur_url="$(grep -E '^APP_URL=' .env 2>/dev/null | cut -d= -f2- | tr -d '"')"
    echo "    Current APP_URL: ${cur_url:-<none>}"
    read -rp "  Public panel URL (e.g. https://panel.yourdomain.com) [Enter = keep]: " new_url
    new_url="${new_url:-$cur_url}"
    new_url="${new_url%/}"
    if [[ -z "$new_url" ]]; then
        _frosty_fail "No URL"
        return 1
    fi
    [[ "$new_url" =~ ^https?:// ]] || new_url="https://${new_url}"

    sed -i "s|^APP_URL=.*|APP_URL=${new_url}|" .env
    if grep -q '^TRUSTED_PROXIES=' .env; then
        sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|' .env
    else
        echo 'TRUSTED_PROXIES=*' >> .env
    fi

    # Some panel versions hardcode proxies in config/trustedproxy.php instead of reading the env var.
    if [[ -f config/trustedproxy.php ]] && ! grep -q "env('TRUSTED_PROXIES'" config/trustedproxy.php; then
        cp config/trustedproxy.php /var/backups/frosty_trustedproxy.php.bak 2>/dev/null
        sed -i -E "s#('proxies'[[:space:]]*=>)[^,]*,#\1 '*',#" config/trustedproxy.php
    fi

    "$php_bin" artisan config:clear >/dev/null 2>&1
    "$php_bin" artisan cache:clear  >/dev/null 2>&1
    "$php_bin" artisan view:clear   >/dev/null 2>&1
    "$php_bin" artisan queue:restart >/dev/null 2>&1
    chown -R www-data:www-data "${FROSTY_PANEL_DIR}" 2>/dev/null
    if [[ -d /run/systemd/system ]]; then
        systemctl restart "php${FROSTY_PHP_VERSION:-8.3}-fpm" >/dev/null 2>&1
    else
        pm2 restart php-fpm >/dev/null 2>&1
    fi

    _frosty_ok "APP_URL=${new_url}, TRUSTED_PROXIES=* applied"
    echo "    Hard-refresh the panel (Ctrl+Shift+R) and try Node -> Configuration -> Generate Token again."
    return 0
}

panel_installed() {
    [[ -f "${FROSTY_PANEL_DIR}/artisan" ]]
}

show_panel_submenu() {
    clear
    print_banner
    echo -e "${C_FROST}${C_BOLD}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}        ${C_ICE}${C_BOLD}❄  P A N E L   M A N A G E R  ❄${C_RESET}        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[1]${C_RESET} ${C_WHITE}Add User${C_RESET}                                 ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_PURPLE}[2]${C_RESET} ${C_WHITE}Update Panel${C_RESET}                             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_RED}[3]${C_RESET} ${C_WHITE}Uninstall Panel${C_RESET}                          ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_CYAN}[4]${C_RESET} ${C_WHITE}Fix HTTPS / Token Generation${C_RESET}             ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}  ${C_BLUE}[5]${C_RESET} ${C_WHITE}Back to Main Menu${C_RESET}                        ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}║${C_RESET}                                                ${C_FROST}${C_BOLD}║${C_RESET}"
    echo -e "${C_FROST}${C_BOLD}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    read -rp "  Select an option [1-5]: " sub_choice

    case "$sub_choice" in
        1) panel_add_user ;;
        2) panel_update ;;
        3) panel_uninstall ;;
        4) panel_apply_proxy_fix ;;
        5) return 0 ;;
        *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
    esac

    echo ""
    read -rp "  Press Enter to continue..." _
}
