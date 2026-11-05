#!/usr/bin/env bash
set -uo pipefail

configure_panel_database() {
    echo ""
    echo "== Configuring MariaDB for Pterodactyl =="

    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }

    local existing_db_pass
    existing_db_pass="$(grep -E '^DB_PASSWORD=' .env 2>/dev/null | cut -d= -f2-)"

    if [[ -z "$existing_db_pass" ]]; then
        local db_pass
        db_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

        echo "    Creating database and user..."
        mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

        if [[ $? -eq 0 ]]; then
            _frosty_ok "Database 'panel' and user 'pterodactyl' created"
        else
            _frosty_fail "Database/user creation failed"
            return 1
        fi

        sed -i \
            -e "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" \
            -e "s/^DB_PORT=.*/DB_PORT=3306/" \
            -e "s/^DB_DATABASE=.*/DB_DATABASE=panel/" \
            -e "s/^DB_USERNAME=.*/DB_USERNAME=pterodactyl/" \
            -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${db_pass}/" \
            .env

        _frosty_ok "Database credentials written to .env"
        echo -e "    ${C_YELLOW:-}Generated DB password (save this if needed): ${db_pass}${C_RESET:-}"
        existing_db_pass="$db_pass"
    else
        _frosty_ok "Database credentials already present in .env"
    fi

    # Self-heal: verify the live MySQL user's password actually matches .env.
    # This catches drift from uninstall/reinstall cycles or manual DB changes.
    echo "    Verifying database credentials are in sync..."
    if mysql -u pterodactyl -p"${existing_db_pass}" -h 127.0.0.1 -e "SELECT 1;" panel >/dev/null 2>&1; then
        _frosty_ok "Database credentials verified working"
    else
        _frosty_warn "Database password out of sync with .env — repairing automatically"

        mysql -u root -e "
            CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${existing_db_pass}';
            ALTER USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${existing_db_pass}';
            CREATE DATABASE IF NOT EXISTS panel;
            GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
        " 2>/tmp/frosty_db_repair.log

        if mysql -u pterodactyl -p"${existing_db_pass}" -h 127.0.0.1 -e "SELECT 1;" panel >/dev/null 2>&1; then
            _frosty_ok "Database credentials repaired and verified"
        else
            _frosty_fail "Could not repair database credentials — see /tmp/frosty_db_repair.log"
            return 1
        fi
    fi

    echo "    Running migrations..."
    if php"${FROSTY_PHP_VERSION:-8.3}" artisan migrate --seed --force >/tmp/frosty_migrate.log 2>&1; then
        _frosty_ok "Database migrations completed"
    else
        _frosty_fail "Migrations failed — see /tmp/frosty_migrate.log"
        return 1
    fi

    return 0
}
