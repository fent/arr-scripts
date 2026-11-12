#!/bin/bash

# Monthly ZFS Scrub: Initiates a scrub on all healthy imported ZFS pools, waits
# for completion, and sends an Unraid notification if any data errors are found.

DRY_RUN="${DRY_RUN:-false}"
WAIT_FOR_COMPLETION="${WAIT_FOR_COMPLETION:-true}"
NOTIFY_BIN="/usr/local/emhttp/webGui/scripts/notify"

set -euo pipefail

if ! command -v zpool > /dev/null 2>&1; then
    echo "zpool command not found; exiting."
    exit 0
fi

mapfile -t POOLS < <(zpool list -H -o name 2> /dev/null || true)
if [ "${#POOLS[@]}" -eq 0 ]; then
    echo "No imported ZFS pools found."
    exit 0
fi

if [ "${DRY_RUN}" = "true" ]; then
    echo "Dry Run Mode: ${DRY_RUN}"
fi

STARTED_POOLS=()
for pool in "${POOLS[@]}"; do
    status_out="$(zpool status "${pool}")"
    if printf '%s\n' "${status_out}" | grep -qE "scan: (scrub|resilver) in progress"; then
        echo "Skipping ${pool}: scrub or resilver already in progress."
        continue
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY_RUN] Would run: zpool scrub ${pool}"
    else
        echo "Starting ZFS scrub on pool '${pool}'..."
        zpool scrub "${pool}"
        STARTED_POOLS+=("${pool}")
    fi
done

if [ "${DRY_RUN}" = "true" ] || [ "${WAIT_FOR_COMPLETION}" != "true" ] || [ "${#STARTED_POOLS[@]}" -eq 0 ]; then
    exit 0
fi

for pool in "${STARTED_POOLS[@]}"; do
    while zpool status "${pool}" | grep -q "scan: scrub in progress"; do
        sleep 30
    done

    status_out="$(zpool status "${pool}")"
    scan_line="$(printf '%s\n' "${status_out}" | awk '/^[[:space:]]*scan:/ { sub(/^[[:space:]]+/, ""); print; exit }')"
    errors_line="$(printf '%s\n' "${status_out}" | awk '/^[[:space:]]*errors:/ { sub(/^[[:space:]]+/, ""); print; exit }')"
    state_line="$(printf '%s\n' "${status_out}" | awk '/^[[:space:]]*state:/ { print $2; exit }')"

    echo "Completed '${pool}': state=${state_line} | ${scan_line} | ${errors_line}"

    if [ "${state_line}" != "ONLINE" ] || [ "${errors_line}" != "errors: No known data errors" ]; then
        if [ -x "${NOTIFY_BIN}" ]; then
            "${NOTIFY_BIN}" -e "ZFS Scrub" -s "ZFS Scrub Alert (${pool})" -d "${state_line}: ${scan_line} (${errors_line})" -i "alert"
        fi
    fi
done
