#!/bin/bash

# Pre-Snapshot Hook: Mirror Unraid USB flash drive (/boot) into its encrypted
# ZFS dataset (/mnt/cache/backups/<hostname>_flash) prior to Sanoid snapshot.

DRY_RUN="${DRY_RUN:-false}"
BOOT_DIR="${BOOT_DIR:-/boot}"
HOST_NAME="${HOST_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
DEST_DIR="${DEST_DIR:-/mnt/cache/backups/${HOST_NAME}_flash}"

set -euo pipefail

if [ ! -d "${BOOT_DIR}/config" ] || [ ! -f "${BOOT_DIR}/bzimage" ]; then
    echo "Error: ${BOOT_DIR} does not appear to be a mounted Unraid boot flash drive." >&2
    exit 1
fi

if ! mountpoint -q "${DEST_DIR}"; then
    echo "Error: Destination ${DEST_DIR} is not a mounted filesystem." >&2
    exit 1
fi

RSYNC_ARGS=(-a --modify-window=1 --delete)
if [ "${DRY_RUN}" = "true" ]; then
    echo "Dry Run Mode: ${DRY_RUN}"
    RSYNC_ARGS+=(-n -v)
fi

rsync "${RSYNC_ARGS[@]}" "${BOOT_DIR}/" "${DEST_DIR}/"

if [ "${DRY_RUN}" != "true" ]; then
    chown root:root "${DEST_DIR}"
    chmod 700 "${DEST_DIR}"
fi
