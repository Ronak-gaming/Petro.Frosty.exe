#!/usr/bin/env bash
set -uo pipefail

repair_all_services() {
    echo ""
    echo -e "${C_CYAN:-}== Frosty Repair: Starting All Services ==${C_RESET:-}"
    echo ""

    load_module "pm2.sh"
    if [[ ! -d /run/systemd/system ]]; then
        _frosty_pm2_resurrect
    fi

    # MariaDB
       if mysqladmin ping >/dev/null 2>&1; then
        _frosty_ok "MariaDB already running"
    else
        echo "    Starting MariaDB..."
        mkdir -p /run/mysqld
        chown mysql:mysql /run/mysqld 2>/dev/null
        chmod 755 /run/mysqld 2>/dev/null
        if [[ -d /run/systemd/system ]]; then
            systemctl restart mariadb >/dev/null 2>&1
        elif command -v pm2 >/dev/null 2>&1; then
            _frosty_pm2_start "mariadb" "/" "/usr/sbin/mariadbd" "--user=mysql" >/dev/null 2>&1
        else
            service mariadb start >/dev/null 2>&1
        fi
        sleep 3
        mysqladmin ping >/dev/null 2>&1 && _frosty_ok "MariaDB started" || _frosty_fail "MariaDB failed to start"
    fi
    # Redis
        if redis-cli ping 2>/dev/null | grep -q PONG; then
        _frosty_ok "Redis already running"
    else
        echo "    Starting Redis..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart redis-server >/dev/null 2>&1
        elif command -v pm2 >/dev/null 2>&1; then
            _frosty_pm2_start "redis" "/" "redis-server" "--daemonize" "no" >/dev/null 2>&1
        else
            redis-server --daemonize yes >/dev/null 2>&1
        fi
        sleep 2
        redis-cli ping 2>/dev/null | grep -q PONG && _frosty_ok "Redis started" || _frosty_fail "Redis failed to start"
    fi
    # Docker
    if docker info >/dev/null 2>&1; then
        _frosty_ok "Docker already running"
    else
        echo "    Starting Docker..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart docker >/dev/null 2>&1
        else
            if [[ -f /var/run/docker.pid ]]; then
                local stale_pid
                stale_pid="$(cat /var/run/docker.pid 2>/dev/null)"
                if [[ -n "$stale_pid" ]]; then
                    kill -9 "$stale_pid" 2>/dev/null
                fi
                rm -f /var/run/docker.pid
            fi
            pkill -x dockerd >/dev/null 2>&1
            sleep 1
            dockerd >/tmp/frosty_dockerd.log 2>&1 &
            sleep 5
        fi
        docker info >/dev/null 2>&1 && _frosty_ok "Docker started" || _frosty_fail "Docker failed to start"
    fi

    # PHP-FPM
    local fpm_sock="/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.sock"
    local fpm_pid="/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.pid"
    local fpm_pattern="master process \\(.*php/${FROSTY_PHP_VERSION:-8.3}/fpm/php-fpm\\.conf\\)"

    if [[ -S "$fpm_sock" ]] && pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
        _frosty_ok "php-fpm already running"
    else
        if pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
            _frosty_warn "Found existing php-fpm master process(es) with a dead socket — stopping before restart"
            pkill -f "$fpm_pattern" 2>/dev/null
            sleep 1
            pkill -9 -f "$fpm_pattern" 2>/dev/null
        fi
        rm -f "$fpm_sock" "$fpm_pid"
        mkdir -p /run/php
        echo "    Starting php-fpm..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart "php${FROSTY_PHP_VERSION:-8.3}-fpm" >/dev/null 2>&1
        else
            "php-fpm${FROSTY_PHP_VERSION:-8.3}" -D >/tmp/frosty_php_fpm_repair.log 2>&1
        fi
        sleep 2
        if [[ -S "$fpm_sock" ]] && pgrep -f "$fpm_pattern" >/dev/null 2>&1; then
            _frosty_ok "php-fpm started"
        else
            _frosty_fail "php-fpm failed to start"
            "php-fpm${FROSTY_PHP_VERSION:-8.3}" -t 2>&1 | sed 's/^/    /'
        fi
    fi

    # nginx
    local nginx_check
    nginx_check="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null)"
    if [[ "$nginx_check" != "000" ]]; then
        _frosty_ok "nginx already responding (HTTP $nginx_check)"
    else
        echo "    Starting nginx..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart nginx >/dev/null 2>&1
        else
            pkill -f nginx >/dev/null 2>&1
            sleep 1
            nginx >/tmp/frosty_nginx_repair.log 2>&1
        fi
        sleep 2
        nginx_check="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null)"
        if [[ "$nginx_check" != "000" ]]; then
            _frosty_ok "nginx started (HTTP $nginx_check)"
        else
            _frosty_fail "nginx failed to start — see /tmp/frosty_nginx_repair.log"
            nginx -t 2>&1 | tail -10
        fi
    fi

    # Wings
    if command -v wings >/dev/null 2>&1; then
        local wings_up=0
        if [[ -d /run/systemd/system ]] && systemctl is-active --quiet wings 2>/dev/null; then
            wings_up=1
        elif command -v pm2 >/dev/null 2>&1 && pm2 describe wings 2>/dev/null | grep -q "online"; then
            wings_up=1
        elif pgrep -f "^/usr/local/bin/wings" >/dev/null 2>&1; then
            wings_up=1
        fi

        if [[ "$wings_up" -eq 1 ]]; then
            _frosty_ok "Wings already running"
        else
            echo "    Starting Wings..."
            if [[ -d /run/systemd/system ]]; then
                systemctl restart wings >/dev/null 2>&1
                sleep 3
                systemctl is-active --quiet wings && _frosty_ok "Wings started" || _frosty_warn "Wings did not start (check config)"
            else
                if command -v pm2 >/dev/null 2>&1; then
                    _frosty_pm2_start "wings" "/etc/pterodactyl" "/usr/local/bin/wings" >/dev/null 2>&1
                    sleep 2
                    pm2 describe wings 2>/dev/null | grep -q "online" && _frosty_ok "Wings started (pm2)" || _frosty_warn "Wings did not start (check config): pm2 logs wings"
                else
                    _frosty_warn "pm2 unavailable — cannot persistently restart Wings"
                fi
            fi
        fi
    fi

    # Cloudflare Tunnel
    local cf_marker="${HOME}/.frosty_cloudflare_configured"
    if [[ -f "$cf_marker" ]]; then
        local cf_up=0
        if [[ -d /run/systemd/system ]] && systemctl is-active --quiet cloudflared 2>/dev/null; then
            cf_up=1
        elif command -v pm2 >/dev/null 2>&1 && pm2 describe cloudflared 2>/dev/null | grep -q "online"; then
            cf_up=1
        elif pgrep -f "cloudflared tunnel run" >/dev/null 2>&1; then
            cf_up=1
        fi

        if [[ "$cf_up" -eq 1 ]]; then
            _frosty_ok "Cloudflare tunnel already running"
        else
            echo "    Starting Cloudflare tunnel..."
            local cf_token
            cf_token="$(cat "$cf_marker")"
            if [[ -d /run/systemd/system ]]; then
                systemctl restart cloudflared >/dev/null 2>&1
                sleep 3
                systemctl is-active --quiet cloudflared && _frosty_ok "Cloudflare tunnel started" || _frosty_fail "Cloudflare tunnel failed to start"
            else
                if command -v pm2 >/dev/null 2>&1; then
                    _frosty_pm2_start "cloudflared" "${HOME}" "cloudflared" "tunnel" "run" "--token" "$cf_token" >/dev/null 2>&1
                    sleep 2
                    pm2 describe cloudflared 2>/dev/null | grep -q "online" && _frosty_ok "Cloudflare tunnel started (pm2)" || _frosty_fail "Cloudflare tunnel failed to start: pm2 logs cloudflared"
                else
                    _frosty_warn "pm2 unavailable — cannot persistently restart Cloudflare tunnel"
                fi
            fi
        fi
    fi

    # Panel health check — catches a broken PHP boot (bad service provider,
    # missing extension files, etc.) that nginx/php-fpm being "up" won't
    # reveal on their own, since they'll happily return a 500 all day.
    local panel_dir="${FROSTY_PANEL_DIR:-/var/www/pterodactyl}"
    if [[ -f "${panel_dir}/artisan" ]]; then
        local artisan_check
        artisan_check="$(cd "$panel_dir" && "php${FROSTY_PHP_VERSION:-8.3}" artisan --version 2>&1)"
        if echo "$artisan_check" | grep -q "^Laravel Framework"; then
            _frosty_ok "Panel application boots cleanly ($artisan_check)"
        else
            _frosty_fail "Panel application fails to boot — a broken service provider or missing file is likely"
            echo "$artisan_check" | head -10 | sed 's/^/    /'
            _frosty_warn "Common cause: a partially-installed Blueprint extension registered in app/Providers/AppServiceProvider.php"
            _frosty_warn "Check: grep -n Blueprint ${panel_dir}/app/Providers/AppServiceProvider.php"
        fi
    fi

    echo ""
    echo -e "${C_CYAN:-}Repair complete.${C_RESET:-}"
    return 0
}
