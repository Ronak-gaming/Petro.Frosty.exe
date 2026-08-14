#!/usr/bin/env bash
set -uo pipefail

configure_panel_database() {
    echo ""
    echo "== Configuring MariaDB for Pterodactyl =="

    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }

    # Check if DB already configured in .env with a real password
    local existing_db_pass
    existing_db_pass="$(grep -E '^DB_PASSWORD=' .env 2>/dev/null | cut -d= -f2-)"

    if [[ -n "$existing_db_pass" ]]; then
        _frosty_ok "Database credentials already present in .env — skipping DB/user creation"
    else
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

        # Write DB config into .env (never into git)
        sed -i \
            -e "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" \
            -e "s/^DB_PORT=.*/DB_PORT=3306/" \
            -e "s/^DB_DATABASE=.*/DB_DATABASE=panel/" \
            -e "s/^DB_USERNAME=.*/DB_USERNAME=pterodactyl/" \
            -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${db_pass}/" \
            .env

        _frosty_ok "Database credentials written to .env"
        echo -e "    ${C_YELLOW:-}Generated DB password (save this if needed): ${db_pass}${C_RESET:-}"
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
