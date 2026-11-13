#!/bin/bash

# Array-Start User Script: Unlocks encrypted ZFS datasets backed by local keyfiles
# (skipping raw-replicated remote backups with keylocation=prompt) and mounts all
# unlocked, mountable ZFS filesystems.

DRY_RUN="${DRY_RUN:-false}"

set -euo pipefail

if ! command -v zfs > /dev/null 2>&1; then
    echo "zfs command not found; exiting."
    exit 0
fi

if [ "${DRY_RUN}" = "true" ]; then
    echo "Dry Run Mode: ${DRY_RUN}"
fi

# Load keys only for datasets using a local file:// keylocation
while IFS=$'\t' read -r dataset keyloc; do
    [ -n "${dataset}" ] || continue
    keystatus="$(zfs get -H -o value keystatus "${dataset}" 2> /dev/null || true)"
    [ "${keystatus}" = "unavailable" ] || continue

    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY_RUN] Would load key for ${dataset} (${keyloc})"
    else
        echo "Loading key for ${dataset}..."
        if zfs load-key "${dataset}" < /dev/null; then
            echo "Successfully loaded key for ${dataset}."
        else
            echo "Failed to load key for ${dataset}." >&2
        fi
    fi
done < <(zfs get -H -t filesystem,volume -o name,value keylocation | awk -F'\t' '$2 ~ /^file:\/\// {print $1 "\t" $2}')

# Mount all unlocked filesystems with an active mountpoint
while IFS=$'\t' read -r dataset mounted mp canmount keystatus; do
    [ -n "${dataset}" ] || continue
    if [ "${mounted}" = "no" ] && [ "${canmount}" = "on" ] && [ "${mp}" != "none" ] && [ "${mp}" != "legacy" ] && [ "${keystatus}" != "unavailable" ]; then
        if [ "${DRY_RUN}" = "true" ]; then
            echo "[DRY_RUN] Would mount ${dataset} at ${mp}"
        else
            echo "Mounting ${dataset} at ${mp}..."
            if zfs mount "${dataset}" < /dev/null; then
                echo "Successfully mounted ${dataset}."
            else
                echo "Failed to mount ${dataset}." >&2
            fi
        fi
    fi
done < <(zfs list -H -t filesystem -o name,mounted,mountpoint,canmount,keystatus)
