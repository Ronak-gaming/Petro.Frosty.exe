#!/usr/bin/env bash
set -uo pipefail

repair_all_services() {
    echo ""
    echo -e "${C_CYAN:-}== Frosty Repair: Starting All Services ==${C_RESET:-}"
    echo ""

    # MariaDB
    if mysqladmin ping >/dev/null 2>&1; then
        _frosty_ok "MariaDB already running"
    else
        echo "    Starting MariaDB..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart mariadb >/dev/null 2>&1
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
    # A socket FILE existing isn't proof anything's listening on it — and
    # this config has no PID file, so php-fpm can't detect an existing
    # instance on its own. Deleting just the socket without killing the
    # process behind it orphans the old master, which keeps running
    # invisibly and piles up with every repair run.
    local fpm_sock="/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.sock"
    local fpm_pid="/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.pid"
    if [[ -S "$fpm_sock" ]] && pgrep -f "php-fpm${FROSTY_PHP_VERSION:-8.3}: master" >/dev/null 2>&1; then
        _frosty_ok "php-fpm already running"
    else
        if pgrep -f "php-fpm${FROSTY_PHP_VERSION:-8.3}: master" >/dev/null 2>&1; then
            _frosty_warn "Found existing php-fpm master process(es) with a dead socket — stopping before restart"
            pkill -f "php-fpm${FROSTY_PHP_VERSION:-8.3}: master" 2>/dev/null
            sleep 1
            pkill -9 -f "php-fpm${FROSTY_PHP_VERSION:-8.3}: master" 2>/dev/null
        fi
        rm -f "$fpm_sock" "$fpm_pid"
        echo "    Starting php-fpm..."
        if [[ -d /run/systemd/system ]]; then
            systemctl restart "php${FROSTY_PHP_VERSION:-8.3}-fpm" >/dev/null 2>&1
        else
            "php-fpm${FROSTY_PHP_VERSION:-8.3}" -D >/tmp/frosty_php_fpm_repair.log 2>&1
        fi
        sleep 2
        if [[ -S "$fpm_sock" ]] && pgrep -f "php-fpm${FROSTY_PHP_VERSION:-8.3}: master" >/dev/null 2>&1; then
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
        if pgrep -f "^/usr/local/bin/wings" >/dev/null 2>&1 || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet wings 2>/dev/null); then
            _frosty_ok "Wings already running"
        else
            echo "    Starting Wings..."
            if [[ -d /run/systemd/system ]]; then
                systemctl restart wings >/dev/null 2>&1
            else
                cd /etc/pterodactyl 2>/dev/null && nohup wings >/tmp/frosty_wings_repair.log 2>&1 &
            fi
            sleep 3
            (pgrep -f "^/usr/local/bin/wings" >/dev/null 2>&1 || systemctl is-active --quiet wings 2>/dev/null) && _frosty_ok "Wings started" || _frosty_warn "Wings did not start (check config)"
        fi
    fi

    # Cloudflare Tunnel
    local cf_marker="${HOME}/.frosty_cloudflare_configured"
    if [[ -f "$cf_marker" ]]; then
        if pgrep -f "cloudflared tunnel run" >/dev/null 2>&1 || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cloudflared 2>/dev/null); then
            _frosty_ok "Cloudflare tunnel already running"
        else
            echo "    Starting Cloudflare tunnel..."
            if [[ -d /run/systemd/system ]]; then
                systemctl restart cloudflared >/dev/null 2>&1
            else
                local cf_token
                cf_token="$(cat "$cf_marker")"
                nohup cloudflared tunnel run --token "$cf_token" >/tmp/frosty_cf_repair.log 2>&1 &
            fi
            sleep 3
            (pgrep -f "cloudflared tunnel run" >/dev/null 2>&1 || systemctl is-active --quiet cloudflared 2>/dev/null) && _frosty_ok "Cloudflare tunnel started" || _frosty_fail "Cloudflare tunnel failed to start"
        fi
    fi

    echo ""
    echo -e "${C_CYAN:-}Repair complete.${C_RESET:-}"
    return 0
}
