#!/usr/bin/env bash
# Adds routes to the cyclops networks via the Windows host, as seen from
# inside WSL2 (NAT mode):
#   - 10.0.0.0/24    tcyclops (test)       -- Hyper-V "tcyclops-internal" vSwitch
#   - 192.168.2.0/24 cyclops (production)  -- Hyper-V "Homelab" vSwitch
#
# Why this is needed: WSL2 NAT mode puts WSL on its own subnet (e.g. 172.x).
# The Windows host's default-route gateway, as seen from WSL, is also the
# only path back into other Windows-side interfaces -- including both of the
# vSwitches above. That gateway IP is not stable across WSL restarts, so it
# must be detected at runtime rather than hardcoded.

set -euo pipefail

TARGET_NETS=(
    "10.0.0.0/24"
    "192.168.2.0/24"
)
LOG_TAG="[cyclops-route]"

# Detect the current default gateway WSL is using to reach the Windows host.
GATEWAY="$(ip route show default | awk '/^default/ {print $3; exit}')"

if [[ -z "${GATEWAY:-}" ]]; then
    echo "${LOG_TAG} ERROR: could not determine default gateway, aborting." >&2
    exit 1
fi

# Ensures a route to $1 exists via $GATEWAY, replacing a stale one if needed.
# This makes the script safe to re-run (idempotent) rather than relying on
# "only runs once at boot" being strictly true.
ensure_route() {
    local target_net="$1"
    local existing_route existing_via

    existing_route="$(ip route show "${target_net}")"
    if [[ -n "${existing_route}" ]]; then
        existing_via="$(awk '/via/ {print $3; exit}' <<< "${existing_route}")"
        if [[ -n "${existing_via}" && "${existing_via}" == "${GATEWAY}" ]]; then
            echo "${LOG_TAG} Route to ${target_net} via ${GATEWAY} already present. Nothing to do."
            return 0
        fi
        echo "${LOG_TAG} Existing route (${existing_route}) is stale (gateway is now ${GATEWAY}). Replacing."
        if ! sudo ip route del "${target_net}"; then
            echo "${LOG_TAG} WARNING: failed to delete existing route, add may fail." >&2
        fi
    fi

    echo "${LOG_TAG} Adding route: ${target_net} via ${GATEWAY}"
    sudo ip route add "${target_net}" via "${GATEWAY}"
}

for net in "${TARGET_NETS[@]}"; do
    ensure_route "${net}"
done

echo "${LOG_TAG} Done."
