#!/usr/bin/env bash
set -uo pipefail

install_composer() {
    echo ""
    echo "== Installing Composer =="

    if command -v composer >/dev/null 2>&1; then
        _frosty_ok "Composer already installed: $(composer --version 2>/dev/null | head -1)"
        return 0
    fi

    echo "    Downloading Composer installer..."
    if curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php >/tmp/frosty_composer.log 2>&1; then
        if php8.3 /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >>/tmp/frosty_composer.log 2>&1; then
            _frosty_ok "Composer installed: $(composer --version 2>/dev/null | head -1)"
            rm -f /tmp/composer-setup.php
            return 0
        fi
    fi

    _frosty_fail "Composer installation failed — see /tmp/frosty_composer.log"
    return 1
}

configure_panel_env() {
    echo ""
    echo "== Configuring Panel Environment =="

    cd "${FROSTY_PANEL_DIR}" || { _frosty_fail "Cannot cd into ${FROSTY_PANEL_DIR}"; return 1; }

    if [[ ! -f .env ]]; then
        if [[ -f .env.example ]]; then
            cp .env.example .env
            _frosty_ok ".env created from .env.example"
        else
            _frosty_fail ".env.example not found — Panel files may be incomplete"
            return 1
        fi
    else
        _frosty_ok ".env already exists — leaving as-is"
    fi

    echo "    Running composer install (this can take a few minutes)..."
    if COMPOSER_ALLOW_SUPERUSER=1 php8.3 /usr/local/bin/composer install --no-dev --optimize-autoloader --no-interaction >/tmp/frosty_composer_install.log 2>&1; then
        _frosty_ok "Composer dependencies installed"
    else
        _frosty_fail "composer install failed — see /tmp/frosty_composer_install.log"
        return 1
    fi

    # Generate app key only if not already set
    if grep -q "^APP_KEY=$" .env || ! grep -q "^APP_KEY=" .env; then
        if php"${FROSTY_PHP_VERSION:-8.3}" artisan key:generate --force >/tmp/frosty_appkey.log 2>&1; then
            _frosty_ok "Application key generated"
        else
            _frosty_fail "Application key generation failed — see /tmp/frosty_appkey.log"
            return 1
        fi
    else
        _frosty_ok "Application key already set — skipping"
    fi

    # Set cache/session/queue drivers to redis (standard Pterodactyl config)
    php"${FROSTY_PHP_VERSION:-8.3}" artisan p:environment:setup \
        --author="admin@example.com" \
        --url="http://${FROSTY_PUBLIC_IP:-127.0.0.1}" \
        --timezone="UTC" \
        --cache=redis \
        --session=redis \
        --queue=redis \
        --redis-host=localhost \
        --redis-pass="" \
        --redis-port=6379 \
        --settings-ui=true \
        --telemetry=false \
        --no-interaction >/tmp/frosty_env_setup.log 2>&1

    if grep -q "^APP_URL=" .env; then
        _frosty_ok "Panel environment configured (cache/session/queue: redis)"
    else
        _frosty_warn "p:environment:setup may not have completed cleanly — check /tmp/frosty_env_setup.log"
    fi

    return 0
}
