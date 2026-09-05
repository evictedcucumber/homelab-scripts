#!/usr/bin/env bash
# Adds routes to the cyclops networks via the Windows host, as seen from
# inside WSL2 (NAT mode):
#   - 10.0.0.0/24    tcyclops (test)      -- Hyper-V "Homelab" internal vSwitch
#   - 192.168.2.0/24 cyclops (production) -- physical homelab LAN behind the host
#
# Why this is needed: WSL2 NAT mode puts WSL on its own subnet (e.g. 172.x).
# The Windows host's default-route gateway, as seen from WSL, is also the
# only path back into other Windows-side interfaces -- including the vSwitch
# above and anything the host itself can route to. That gateway IP is not
# stable across WSL restarts, so it must be detected at runtime rather than
# hardcoded.
#
# Run by hand after a WSL restart; safe to re-run.

set -euo pipefail

TARGET_NETS=(
    "10.0.0.0/24"
    "192.168.2.0/24"
)
LOG_TAG="[cyclops-route]"

log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
warn() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }

# Detect the current default gateway WSL uses to reach the Windows host.
# Take the address after "via" regardless of field position.
GATEWAY="$(
    ip -4 route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'
)" || true

if [[ -z "${GATEWAY:-}" ]]; then
    warn "ERROR: could not determine default gateway, aborting."
    exit 1
fi

# Ensures a route to $1 exists via $GATEWAY, replacing a stale one if needed.
ensure_route() {
    local target_net="$1"
    local existing_route existing_via

    existing_route="$(ip route show "${target_net}" 2>/dev/null || true)"
    if [[ -n "${existing_route}" ]]; then
        existing_via="$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }' <<<"${existing_route}")"
        if [[ -n "${existing_via}" && "${existing_via}" == "${GATEWAY}" ]]; then
            log "Route to ${target_net} via ${GATEWAY} already present. Nothing to do."
            return 0
        fi
        log "Existing route (${existing_route}) is stale (gateway is now ${GATEWAY}). Replacing."
        if [[ -n "${existing_via}" ]]; then
            sudo ip route del "${target_net}" via "${existing_via}" || warn "WARNING: failed to delete stale route, add may fail."
        else
            sudo ip route del "${target_net}" || warn "WARNING: failed to delete stale route, add may fail."
        fi
    fi

    log "Adding route: ${target_net} via ${GATEWAY}"
    sudo ip route add "${target_net}" via "${GATEWAY}"
}

for net in "${TARGET_NETS[@]}"; do
    ensure_route "${net}"
done

log "Done."
