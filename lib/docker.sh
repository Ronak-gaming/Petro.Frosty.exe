#!/usr/bin/env bash
set -uo pipefail

install_docker() {
    echo ""
    echo "== Installing Docker =="
    if command -v docker >/dev/null 2>&1; then
        _frosty_ok "Docker already installed: $(docker --version)"
    else
        echo "    Installing Docker via official get-docker script..."
        if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/tmp/frosty_docker_install.log && \
           sh /tmp/get-docker.sh >>/tmp/frosty_docker_install.log 2>&1; then
            _frosty_ok "Docker installed"
        else
            _frosty_fail "Docker installation failed — see /tmp/frosty_docker_install.log"
            return 1
        fi
    fi
    if [[ -d /run/systemd/system ]]; then
        systemctl enable docker >/dev/null 2>&1
        systemctl restart docker >/dev/null 2>&1
        if systemctl is-active --quiet docker; then
            _frosty_ok "Docker service running"
        else
            _frosty_fail "Docker service failed to start"
            systemctl status docker --no-pager | tail -20
            return 1
        fi
    else
        _frosty_warn "No systemd — starting dockerd under pm2 for persistence"

        if docker info >/dev/null 2>&1; then
            _frosty_ok "dockerd already running"
        else
            # Clear stale PID file / kill any bare dockerd from a previous
            # run so pm2 owns the only instance bound to the socket —
            # same reasoning as MariaDB/Redis's pm2 migration.
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
            if command -v pm2 >/dev/null 2>&1; then
                pm2 delete dockerd >/dev/null 2>&1
            fi

            load_module "pm2.sh"
            if ! _frosty_ensure_pm2; then
                _frosty_fail "pm2 setup failed — cannot start dockerd persistently"
                return 1
            fi
            # dockerd runs in the foreground by default (no daemon flag),
            # which is exactly what pm2 needs to supervise it.
            if ! _frosty_pm2_start "dockerd" "/" "/usr/bin/dockerd"; then
                echo "    pm2 logs:"
                pm2 logs dockerd --lines 20 --nostream 2>/dev/null
                return 1
            fi
            sleep 3
        fi
    fi

    # dockerd's first-time init (creating bridge networks, iptables
    # chains, etc.) can take longer than a plain restart — same lesson
    # learned from MariaDB's InnoDB init needing more headroom than a
    # short fixed wait allowed for.
    local docker_ready=0
    for i in $(seq 1 15); do
        if docker info >/dev/null 2>&1; then
            docker_ready=1
            break
        fi
        sleep 2
    done
    if [[ "$docker_ready" -eq 1 ]]; then
        _frosty_ok "Docker responding"
    else
        _frosty_fail "Docker not responding — likely blocked by container environment (no --privileged / no DinD)"
        _frosty_warn "This is expected inside restricted containers like Codespaces; will work on a real VPS"
        if [[ ! -d /run/systemd/system ]] && command -v pm2 >/dev/null 2>&1; then
            echo "    pm2 logs:"
            pm2 logs dockerd --lines 20 --nostream 2>/dev/null
        fi
        return 1
    fi
    return 0
}
