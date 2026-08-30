#!/usr/bin/env bash
set -uo pipefail

install_database() {
    echo ""
    echo "== Installing MariaDB =="

    dpkg --configure -a >/tmp/frosty_dpkg_fix.log 2>&1

    if dpkg -s mariadb-server >/dev/null 2>&1; then
        _frosty_ok "mariadb-server already installed"
    else
        echo "    Installing mariadb-server..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client >/tmp/frosty_mariadb_install.log 2>&1; then
            _frosty_ok "mariadb-server installed"
        else
            _frosty_warn "First install attempt failed — running dpkg repair and retrying once..."
            dpkg --configure -a >>/tmp/frosty_mariadb_install.log 2>&1
            DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y >>/tmp/frosty_mariadb_install.log 2>&1
            if DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client >>/tmp/frosty_mariadb_install.log 2>&1; then
                _frosty_ok "mariadb-server installed (after retry)"
            else
                _frosty_fail "MariaDB installation failed after retry — see /tmp/frosty_mariadb_install.log"
                return 1
            fi
        fi
    fi

    # /run is often an ephemeral tmpfs on minimal/containerized hosts and
    # may not have this subdirectory or correct ownership even though the
    # package installed successfully — same class of issue as /run/php.
    mkdir -p /run/mysqld
    chown mysql:mysql /run/mysqld 2>/dev/null
    chmod 755 /run/mysqld 2>/dev/null

    if [[ -d /run/systemd/system ]]; then
        systemctl enable mariadb >/dev/null 2>&1
        systemctl restart mariadb >/dev/null 2>&1
        if systemctl is-active --quiet mariadb; then
            _frosty_ok "mariadb service running"
        else
            _frosty_fail "mariadb service failed to start"
            systemctl status mariadb --no-pager | tail -20
            return 1
        fi
    else
        _frosty_warn "No systemd — starting mariadb manually"
        mkdir -p /run/mysqld
        chown mysql:mysql /run/mysqld 2>/dev/null
        chmod 755 /run/mysqld 2>/dev/null
        service mariadb start >/dev/null 2>&1
        sleep 3
    fi

    local mysql_ready=0
    for i in 1 2 3 4 5; do
        if mysqladmin ping >/dev/null 2>&1; then
            mysql_ready=1
            break
        fi
        sleep 2
    done

    if [[ "$mysql_ready" -eq 1 ]]; then
        local ver
        ver="$(mysql --version 2>/dev/null)"
        _frosty_ok "MariaDB responding: $ver"
    else
        _frosty_fail "MariaDB not responding to ping after install"
        return 1
    fi

    return 0
}

install_redis() {
    echo ""
    echo "== Installing Redis =="

    dpkg --configure -a >/tmp/frosty_dpkg_fix.log 2>&1

    if dpkg -s redis-server >/dev/null 2>&1; then
        _frosty_ok "redis-server already installed"
    else
        echo "    Installing redis-server..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server >/tmp/frosty_redis_install.log 2>&1; then
            _frosty_ok "redis-server installed"
        else
            _frosty_warn "First install attempt failed — running dpkg repair and retrying once..."
            dpkg --configure -a >>/tmp/frosty_redis_install.log 2>&1
            DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y >>/tmp/frosty_redis_install.log 2>&1
            if DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server >>/tmp/frosty_redis_install.log 2>&1; then
                _frosty_ok "redis-server installed (after retry)"
            else
                _frosty_fail "Redis installation failed after retry — see /tmp/frosty_redis_install.log"
                return 1
            fi
        fi
    fi

    if [[ -d /run/systemd/system ]]; then
        systemctl enable redis-server >/dev/null 2>&1
        systemctl restart redis-server >/dev/null 2>&1
        if systemctl is-active --quiet redis-server; then
            _frosty_ok "redis-server service running"
        else
            _frosty_fail "redis-server service failed to start"
            systemctl status redis-server --no-pager | tail -20
            return 1
        fi
    else
        _frosty_warn "No systemd — starting redis manually"
        redis-server --daemonize yes >/dev/null 2>&1
        sleep 2
    fi

    local redis_ready=0
    for i in 1 2 3; do
        if redis-cli ping 2>/dev/null | grep -q "PONG"; then
            redis_ready=1
            break
        fi
        sleep 2
    done

    if [[ "$redis_ready" -eq 1 ]]; then
        _frosty_ok "Redis responding (PONG)"
    else
        _frosty_fail "Redis not responding to ping after install"
        return 1
    fi

    return 0
}
