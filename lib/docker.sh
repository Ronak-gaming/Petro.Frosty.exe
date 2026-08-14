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
        _frosty_warn "No systemd — attempting to start dockerd manually"
        if docker info >/dev/null 2>&1; then
            _frosty_ok "dockerd already running"
        else
            # Clear stale PID file left behind by a dead/killed daemon
            if [[ -f /var/run/docker.pid ]]; then
                local stale_pid
                stale_pid="$(cat /var/run/docker.pid 2>/dev/null)"
                if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
                    rm -f /var/run/docker.pid
                elif [[ -n "$stale_pid" ]]; then
                    kill -9 "$stale_pid" 2>/dev/null
                    sleep 1
                    rm -f /var/run/docker.pid
                fi
            fi
            pkill -x dockerd >/dev/null 2>&1
            sleep 1
            dockerd >/tmp/frosty_dockerd.log 2>&1 &
            sleep 5
        fi
    fi

    local docker_ready=0
    for i in 1 2 3 4 5; do
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
        return 1
    fi

    return 0
}
