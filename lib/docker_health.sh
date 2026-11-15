#!/usr/bin/env bash
set -uo pipefail

# Shared Docker diagnostics for PufferPanel / JTG Panel: finds out WHY containers do not start or images do not pull.

FROSTY_MC_IMAGES=(
    "itzg/minecraft-server:java8"
    "itzg/minecraft-server:java11"
    "itzg/minecraft-server:java17"
    "itzg/minecraft-server:java21"
    "itzg/minecraft-server:java25"
    "itzg/bungeecord:latest"
)

# Turns a raw Docker error into a plain-language cause (empty if unknown).
_frosty_docker_classify() {
    local t="${1,,}"
    case "$t" in
        *"permission denied"*"docker.sock"*|*"permission denied while trying to connect"*|*"got permission denied"*)
            echo "The user running this program is not allowed to use the Docker socket (not in the 'docker' group)." ;;
        *"toomanyrequests"*|*"rate limit"*|*"pull rate"*)
            echo "Docker Hub rate limit reached for this server's IP (anonymous pulls). Run 'docker login' with a free Docker Hub account, or wait a few hours." ;;
        *"no such image"*|*"404"*"image"*)
            echo "The image is not on this server and the automatic pull failed. Use 'Pre-pull images' to see the real pull error." ;;
        *"nft"*|*"iptables"*|*"netlink"*|*"operation not permitted"*|*"permission denied (you must be root)"*)
            echo "This host blocks container networking/firewall changes. Typical in restricted containers (Codespaces, OpenVZ/LXC without nesting, no --privileged). Use a real VPS/VM with systemd, or enable nesting + privileged mode." ;;
        *"cgroup"*|*"oci runtime create failed"*|*"failed to create shim"*|*"operation not supported"*|*"mount"*"invalid argument"*)
            echo "The container runtime cannot create the container here (cgroups/mounts not available — restricted virtualization)." ;;
        *"no space left"*)
            echo "The disk is full (Docker images/layers need space)." ;;
        *"no such host"*|*"temporary failure in name resolution"*|*"i/o timeout"*|*"tls handshake timeout"*|*"dial tcp"*)
            echo "This server cannot reach the Docker registry (DNS/firewall/network problem)." ;;
        *"no matching manifest"*|*"exec format error"*)
            echo "The image does not support this CPU architecture." ;;
        *"cannot connect to the docker daemon"*|*"is the docker daemon running"*)
            echo "The Docker daemon is not running." ;;
        *) echo "" ;;
    esac
}

docker_health_check() {
    echo ""
    echo -e "${C_CYAN:-}== Docker health check ==${C_RESET:-}"
    local out rc cause

    if ! command -v docker >/dev/null 2>&1; then
        _frosty_fail "Docker is not installed"; return 1
    fi
    _frosty_ok "Docker CLI: $(docker --version 2>/dev/null)"

    if [[ -d /run/systemd/system ]]; then _frosty_ok "systemd: yes"; else _frosty_warn "systemd: NO (containers/restricted environment — Docker is often unreliable here)"; fi

    out="$(docker info 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        _frosty_fail "Docker daemon is not reachable"
        echo "$out" | tail -n 3 | sed 's/^/      /'
        cause="$(_frosty_docker_classify "$out")"; [[ -n "$cause" ]] && echo -e "    ${C_YELLOW:-}Cause:${C_RESET:-} $cause"
        return 1
    fi
    _frosty_ok "Docker daemon reachable (server $(docker info --format '{{.ServerVersion}}' 2>/dev/null), storage: $(docker info --format '{{.Driver}}' 2>/dev/null), cgroup v$(docker info --format '{{.CgroupVersion}}' 2>/dev/null))"

    local free_gb
    free_gb="$(df -BG --output=avail "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" 2>/dev/null | tail -1 | tr -dc '0-9')"
    [[ -n "$free_gb" ]] && { (( free_gb < 5 )) && _frosty_warn "Only ${free_gb} GB free for Docker (Minecraft images need several GB)" || _frosty_ok "Free disk for Docker: ${free_gb} GB"; }

    # Registry reachability + anonymous pull allowance (official Docker Hub rate-limit check)
    local token hdr remaining
    token="$(curl -s -m 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("token",""))' 2>/dev/null)"
    if [[ -z "$token" ]]; then
        _frosty_fail "Cannot reach Docker Hub (auth.docker.io) — DNS/firewall problem on this server"
    else
        hdr="$(curl -sI -m 10 -H "Authorization: Bearer ${token}" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest 2>/dev/null | tr -d '\r')"
        remaining="$(grep -i '^ratelimit-remaining:' <<< "$hdr" | head -1 | sed 's/.*: *//')"
        if [[ -n "$remaining" ]]; then
            _frosty_ok "Docker Hub reachable — anonymous pulls left: ${remaining}"
            [[ "${remaining%%;*}" =~ ^[0-9]+$ ]] && (( ${remaining%%;*} < 5 )) && _frosty_warn "Almost out of anonymous pulls — run 'docker login'"
        else
            _frosty_ok "Docker Hub reachable"
        fi
    fi

    echo "    Pull + run test (hello-world)..."
    out="$(timeout 180 docker pull hello-world 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        _frosty_fail "Pulling an image FAILED"
        echo "$out" | tail -n 3 | sed 's/^/      /'
        cause="$(_frosty_docker_classify "$out")"; [[ -n "$cause" ]] && echo -e "    ${C_YELLOW:-}Cause:${C_RESET:-} $cause"
        return 1
    fi
    _frosty_ok "Pulling images works"

    out="$(timeout 60 docker run --rm hello-world 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _frosty_ok "Starting a container works (default network)"
    else
        _frosty_fail "Starting a container FAILED"
        echo "$out" | tail -n 4 | sed 's/^/      /'
        cause="$(_frosty_docker_classify "$out")"; [[ -n "$cause" ]] && echo -e "    ${C_YELLOW:-}Cause:${C_RESET:-} $cause"
        if timeout 60 docker run --rm --network none hello-world >/dev/null 2>&1; then
            echo -e "    ${C_YELLOW:-}Containers start with --network none but not with networking: Docker's network/firewall setup is blocked on this host.${C_RESET:-}"
        else
            echo -e "    ${C_YELLOW:-}Containers cannot start at all here — Docker is not usable in this environment.${C_RESET:-}"
        fi
        return 1
    fi

    # Socket / group access for the panel service users
    if [[ -S /var/run/docker.sock ]]; then
        echo "    Docker socket: $(ls -l /var/run/docker.sock | awk '{print $1, $3, $4}')"
    fi
    local u
    for u in pufferpanel; do
        if id "$u" >/dev/null 2>&1; then
            if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
                _frosty_ok "User '$u' is in the docker group"
            else
                _frosty_warn "User '$u' is NOT in the docker group (PufferPanel -> use 'Fix Docker access')"
            fi
        fi
    done
    _frosty_ok "Docker looks healthy"
    return 0
}

# Pull the Minecraft images JTG Panel needs (visible errors instead of silent failures).
# Usage: docker_pull_images [image ...]   (no args = the default list)
docker_pull_images() {
    echo ""
    echo -e "${C_CYAN:-}== Pre-pulling Minecraft Docker images ==${C_RESET:-}"
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        _frosty_fail "Docker is not working — run the Docker health check first"; return 1
    fi
    local images=("$@") img n=0 ok=0 fail=0 log out cause
    [[ ${#images[@]} -eq 0 ]] && images=("${FROSTY_MC_IMAGES[@]}")
    for img in "${images[@]}"; do
        n=$(( n + 1 ))
        if docker image inspect "$img" >/dev/null 2>&1; then
            _frosty_ok "${img} (already present)"; ok=$(( ok + 1 )); continue
        fi
        echo "    [${n}/${#images[@]}] Pulling ${img} (can take a few minutes)..."
        log="/tmp/frosty_pull_${n}.log"
        if timeout 1800 docker pull "$img" >"$log" 2>&1; then
            _frosty_ok "${img}"; ok=$(( ok + 1 ))
        else
            fail=$(( fail + 1 ))
            out="$(tail -n 4 "$log")"
            _frosty_fail "${img} — pull failed"
            echo "$out" | sed 's/^/      /'
            cause="$(_frosty_docker_classify "$out")"; [[ -n "$cause" ]] && echo -e "      ${C_YELLOW:-}Cause:${C_RESET:-} $cause"
        fi
    done
    echo "    Done: ${ok} ready, ${fail} failed."
    [[ $fail -eq 0 ]]
}
