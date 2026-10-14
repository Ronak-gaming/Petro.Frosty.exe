#!/usr/bin/env bash
set -uo pipefail

_frosty_check_mem() {
    local mem_free_mb swap_total_mb
    mem_free_mb=$(free -m | awk '/^Mem:/{print $7}')
    swap_total_mb=$(free -m | awk '/^Swap:/{print $2}')

    if [[ -n "${mem_free_mb}" && "${mem_free_mb}" -lt 512 && "${swap_total_mb:-0}" -eq 0 ]]; then
        _frosty_warn "Low available memory (${mem_free_mb}MB) and no swap detected."
        _frosty_warn "Composer can hang or get silently OOM-killed under these conditions."
        echo "    Creating a temporary 1GB swapfile at /swapfile to prevent hangs..."
        if [[ ! -f /swapfile ]]; then
            fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile 2>/dev/null && _frosty_ok "Swapfile enabled" || _frosty_warn "Could not enable swapfile (may need different permissions in this environment)"
        fi
    fi
}

install_composer() {
    echo ""
    echo "== Installing Composer =="

    if command -v composer >/dev/null 2>&1; then
        _frosty_ok "Composer already installed: $(composer --version 2>/dev/null | head -1)"
        return 0
    fi

    _frosty_check_mem

    echo "    Downloading Composer installer..."
    : > /tmp/frosty_composer.log
    timeout 120 curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php >>/tmp/frosty_composer.log 2>&1 < /dev/null
    if [[ $? -ne 0 || ! -s /tmp/composer-setup.php ]]; then
        _frosty_fail "Composer download failed or timed out — see /tmp/frosty_composer.log"
        return 1
    fi

    echo "    Running Composer installer (this should take under a minute)..."
    tail -f /tmp/frosty_composer.log --pid=$$ & local tail_pid=$!
    timeout 180 "php${FROSTY_PHP_VERSION:-8.3}" /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >>/tmp/frosty_composer.log 2>&1 < /dev/null
    local rc=$?
    kill "${tail_pid}" 2>/dev/null

    if [[ ${rc} -eq 0 ]]; then
        _frosty_ok "Composer installed: $(composer --version 2>/dev/null | head -1)"
        rm -f /tmp/composer-setup.php
        return 0
    fi

    _frosty_fail "Composer installation failed or timed out — see /tmp/frosty_composer.log"
    return 1
}

setup_panel_queue_and_cron() {
    echo "    Configuring Panel cron job and queue worker (pteroq)..."
    local php_bin
    php_bin="$(command -v "php${FROSTY_PHP_VERSION:-8.3}" || echo "/usr/bin/php${FROSTY_PHP_VERSION:-8.3}")"
    local cron_entry="* * * * * ${php_bin} ${FROSTY_PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"

    (crontab -l 2>/dev/null | grep -v "artisan schedule:run"; echo "$cron_entry") | crontab - 2>/dev/null || true
    _frosty_ok "Cron job configured for artisan schedule:run"

    if [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/pteroq.service << PTEROQEOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=${php_bin} ${FROSTY_PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
PTEROQEOF
        systemctl daemon-reload
        systemctl enable --now pteroq.service >/dev/null 2>&1
        if systemctl is-active --quiet pteroq.service; then
            _frosty_ok "pteroq queue worker running (systemd)"
        else
            _frosty_warn "pteroq service did not start cleanly — check: systemctl status pteroq"
        fi
    else
        load_module "pm2.sh"
        if _frosty_ensure_pm2; then
            _frosty_pm2_start "pteroq" "${FROSTY_PANEL_DIR}" "$php_bin" "artisan" "queue:work" "--queue=high,standard,low" "--sleep=3" "--tries=3" >/dev/null 2>&1 && \
                _frosty_ok "pteroq queue worker running (pm2)" || \
                _frosty_warn "Could not start pteroq under pm2"
        fi
    fi
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

    _frosty_check_mem

    echo "    Running composer install (this can take a few minutes, output below)..."
    local composer_attempt=1
    local composer_ok=0
    while [[ ${composer_attempt} -le 2 ]]; do
        : > /tmp/frosty_composer_install.log
        tail -f /tmp/frosty_composer_install.log --pid=$$ & local tail_pid=$!

        COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 \
            timeout 900 "php${FROSTY_PHP_VERSION:-8.3}" /usr/local/bin/composer install \
                --no-dev --optimize-autoloader --no-interaction --no-ansi \
                >>/tmp/frosty_composer_install.log 2>&1 < /dev/null
        local rc=$?
        kill "${tail_pid}" 2>/dev/null

        if [[ ${rc} -eq 0 ]]; then
            composer_ok=1
            break
        fi

        if [[ ${composer_attempt} -eq 1 ]]; then
            _frosty_warn "composer install failed or timed out (attempt 1/2) — clearing cache and retrying..."
            "php${FROSTY_PHP_VERSION:-8.3}" /usr/local/bin/composer clear-cache >/dev/null 2>&1 < /dev/null
        fi
        composer_attempt=$((composer_attempt + 1))
    done

    if [[ ${composer_ok} -eq 1 ]]; then
        _frosty_ok "Composer dependencies installed"
    else
        _frosty_fail "composer install failed after retry — see /tmp/frosty_composer_install.log"
        _frosty_warn "If it timed out (not errored), the host likely has too little RAM/swap for composer's dependency solver."
        return 1
    fi

    if grep -q "^APP_KEY=$" .env || ! grep -q "^APP_KEY=" .env; then
        if "php${FROSTY_PHP_VERSION:-8.3}" artisan key:generate --force >/tmp/frosty_appkey.log 2>&1; then
            _frosty_ok "Application key generated"
        else
            _frosty_fail "Application key generation failed — see /tmp/frosty_appkey.log"
            return 1
        fi
    else
        _frosty_ok "Application key already set — skipping"
    fi

    "php${FROSTY_PHP_VERSION:-8.3}" artisan p:environment:setup \
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

    setup_panel_queue_and_cron
    return 0
}
