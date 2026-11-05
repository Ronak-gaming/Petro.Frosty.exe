#!/usr/bin/env bash
set -uo pipefail

configure_panel_nginx() {
    echo ""
    echo "== Configuring Nginx for Pterodactyl =="

    if ! command -v nginx >/dev/null 2>&1; then
        echo "    Installing nginx..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/tmp/frosty_nginx_install.log 2>&1; then
            _frosty_ok "nginx installed"
        else
            _frosty_fail "nginx installation failed — see /tmp/frosty_nginx_install.log"
            return 1
        fi
    else
        _frosty_ok "nginx already installed"
    fi

    chown -R www-data:www-data "${FROSTY_PANEL_DIR}" 2>/dev/null || true

    local php_sock="/run/php/php${FROSTY_PHP_VERSION:-8.3}-fpm.sock"

    cat > /etc/nginx/sites-available/pterodactyl.conf << NGINXEOF
server {
    listen 80;
    server_name _;

    root ${FROSTY_PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${php_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/default

    if nginx -t >/tmp/frosty_nginx_test.log 2>&1; then
        _frosty_ok "nginx config valid"
    else
        _frosty_fail "nginx config test failed — see /tmp/frosty_nginx_test.log"
        return 1
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable nginx >/dev/null 2>&1
        systemctl restart nginx >/dev/null 2>&1
        if systemctl is-active --quiet nginx; then
            _frosty_ok "nginx service running"
        else
            _frosty_fail "nginx failed to start"
            systemctl status nginx --no-pager | tail -20
            return 1
        fi
    else
        _frosty_warn "No systemd — starting nginx under pm2 for persistence"

        # Kill any bare background nginx from a previous run so pm2 owns
        # the only instance bound to port 80.
        service nginx stop >/dev/null 2>&1
        pkill -f "nginx: master process" >/dev/null 2>&1
        sleep 1
        if command -v pm2 >/dev/null 2>&1; then
            pm2 delete nginx >/dev/null 2>&1
        fi

        load_module "pm2.sh"
        if ! _frosty_ensure_pm2; then
            _frosty_fail "pm2 setup failed — cannot start nginx persistently"
            return 1
        fi
        # -g 'daemon off;' keeps nginx in the foreground, required for pm2
        # to supervise it (nginx normally forks and exits immediately,
        # which pm2 would just see as an instant crash-loop).
        if ! _frosty_pm2_start "nginx" "/" "nginx" "-g" "daemon off;"; then
            echo "    pm2 logs:"
            pm2 logs nginx --lines 20 --nostream 2>/dev/null
            return 1
        fi
        sleep 1
    fi

    local http_check
    http_check="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null)"
    if [[ "$http_check" == "200" || "$http_check" == "302" ]]; then
        _frosty_ok "Panel responding locally (HTTP $http_check)"
        echo -e "    ${C_CYAN:-}Panel URL: http://${FROSTY_PUBLIC_IP:-YOUR_SERVER_IP}${C_RESET:-}"
    else
        _frosty_warn "Panel HTTP check returned: $http_check (may still need php-fpm running)"
    fi

    return 0
}
