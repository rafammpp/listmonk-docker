#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

section() {
    printf '\n== %s ==\n' "$1"
}

info() {
    printf '[INFO] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1"
}

error_msg() {
    printf '[ERROR] %s\n' "$1"
}

as_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
        return
    fi

    if sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
        return
    fi

    return 126
}

show_privileged_or_warn() {
    local description=$1
    shift

    if ! as_root "$@"; then
        warn "${description} requires root (run with sudo for full checks)."
    fi
}

show_expected_ports() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        warn "Compose file not found at ${COMPOSE_FILE}."
        return
    fi

    info "Expected published ports from ${COMPOSE_FILE}:"
    grep -nE '127\.0\.0\.1:9000:9000|80:80|443:443' "$COMPOSE_FILE" || true
}

show_listening_ports() {
    local port output addresses

    output=$(ss -H -ltn 2>/dev/null | grep -E ':(22|80|443|9000)\b' || true)
    if [[ -z "$output" ]]; then
        warn "No listening sockets found for ports 22, 80, 443, or 9000."
        return
    fi

    printf '%s\n' "$output"

    addresses=$(printf '%s\n' "$output" | awk '{print $4}')
    if printf '%s\n' "$addresses" | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\[::\]):9000$'; then
        error_msg "Port 9000 is listening on a public address. It should stay bound to 127.0.0.1 only."
    elif printf '%s\n' "$addresses" | grep -Eq '(^|[[:space:]])(127\.0\.0\.1|\[::1\]):9000$'; then
        info "Port 9000 is only listening on loopback, which matches the compose file."
    else
        info "Port 9000 is not listening, or it is being published differently than expected."
    fi
}

show_ufw_status() {
    show_privileged_or_warn "UFW status" ufw status verbose
}

show_ufw_rules() {
    show_privileged_or_warn "UFW numbered rules" ufw status numbered
}

show_docker_user_chain() {
    local rules num_rules

    if ! rules=$(as_root iptables -S DOCKER-USER 2>/dev/null); then
        warn "Could not inspect the DOCKER-USER chain."
        return
    fi

    printf '%s\n' "$rules"

    num_rules=$(printf '%s\n' "$rules" | grep -c '^-A DOCKER-USER ' || true)

    if [[ "$num_rules" -eq 0 ]]; then
        warn "DOCKER-USER is empty. If Docker publishes ports, UFW can be bypassed for container traffic."
    elif [[ "$num_rules" -eq 1 ]] \
        && printf '%s\n' "$rules" | grep -q '^-A DOCKER-USER -j RETURN$'; then
        warn "DOCKER-USER has no filtering rules. If Docker publishes ports, UFW can be bypassed for container traffic."
    else
        info "DOCKER-USER contains custom rules."
    fi
}

show_forward_chain() {
    show_privileged_or_warn "iptables FORWARD chain" sh -c 'iptables -S FORWARD | sed -n "1,40p"'
}

show_docker_ports() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker CLI is not installed."
        return
    fi

    if ! docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null; then
        warn "Cannot talk to the Docker daemon as the current user."
    fi
}

print_verdict() {
    cat <<'EOF'

Interpretation guide:
- If UFW is active but DOCKER-USER is empty or only contains `-j RETURN`, Docker-published ports may bypass UFW.
- In this project, ports 80 and 443 are expected to be public, and 9000 should stay on 127.0.0.1 only.
- To prove UFW is really blocking something, the final check must be external: test from another host against a port that should be closed.
EOF
}

main() {
    section "Environment"
    info "Repository root: ${ROOT_DIR}"
    info "Running as: $(id -un)"
    if sudo -n true >/dev/null 2>&1; then
        info "Passwordless sudo is available for deep checks."
    else
        warn "Passwordless sudo is not available in this shell. Some checks will be partial unless you run this script with sudo."
    fi

    section "Expected exposure from compose"
    show_expected_ports

    section "Listening sockets"
    show_listening_ports

    section "UFW status"
    show_ufw_status

    section "UFW rules"
    show_ufw_rules

    section "Docker published ports"
    show_docker_ports

    section "DOCKER-USER chain"
    show_docker_user_chain

    section "FORWARD chain"
    show_forward_chain

    print_verdict
}

main "$@"