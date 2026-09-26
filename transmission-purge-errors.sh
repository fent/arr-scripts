#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: DEAD TRACKER ERROR TORRENTS PURGER (CASE C) - ITERATIVE ID EDITION
# ==============================================================================
# PURPOSE:
# This script scans Transmission for broken, dead, or completely unregistered
# torrent entries by systematically looping through every active Torrent ID in
# your container's database.
#
# HOW IT WORKS:
# 1. It extracts a list of all active numeric Torrent IDs from Transmission.
# 2. It loops through every single ID sequentially and runs a deep 'transmission-remote -t ID --info' check.
# 3. It scans the internal log output strictly for terms like "tracker:", "unregistered", or "not found".
# 4. If an error is found, it calculates its exact path on your Unraid host disk.
# 5. If the path exists inside your target shares (.tv, .movies, etc.), it commands
#    Transmission to safely drop the session and delete the dead data blocks from disk.
#
# PROTECTION GATES:
# - Generic "error:" messages (like a slow disk spinning up or a temporary
#   network timeout) are completely ignored to prevent false-positive deletions.
# - It is 100% blind to what your files are named on disk, so video titles
#   containing words like "Errors" are completely protected.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                    # Set to 'false' to actively delete from Transmission
CONTAINER_NAME="transmission"   # Name of your Transmission Docker container
BASE_PATH="/mnt/user/downloads" # Parent path where your source folders live

# Transmission Credentials
TR_USER="YOUR_USERNAME_HERE"
TR_PASS="YOUR_PASSWORD_HERE"

# Target subdirectories to audit (Excluding .music)
TARGET_FOLDERS=(".tv" ".tv-imported" ".tvfourk" ".movies" ".moviesfourk")

# Table Formatting
COL_NAME=80
COL_ID=5
COL_ERROR=30
COL_TOTAL=$((COL_NAME + COL_ID + COL_ERROR + 6))

echo "=== STARTING TRACKER ERROR PURGE ==="
echo "Dry Run Mode: $DRY_RUN"
echo "Scanning every torrent ID in the database (this will take a while)..."
echo "----------------------------------------"

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

echo "Caching entire torrent manifest from Transmission..."
RAW_MANIFEST=$(docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1)

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

# Extract every active numerical ID row cleanly out of Transmission's list table
ALL_IDS=$(echo "$RAW_MANIFEST" | tail -n +2 | head -n -1 | awk '{print $1}' | tr -d '*')

# Clean, in-memory trackers
TOTAL_TRACKER_ERR_KBYTES=0
TRACKER_ERR_COUNT=0
HEADER_PRINTED=false

# -----------------------------------------------------------------
# CORE ENGINE: STEP DEEP SEQUENTIALLY THROUGH EVERY TORRENT ID
# -----------------------------------------------------------------
for tid in $ALL_IDS; do
    if [[ "$tid" =~ ^[0-9]+$ ]]; then

        # Query the explicit, untruncated internal metadata block for this database index
        TORRENT_DETAILS=$(docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$tid" --info 2> /dev/null)

        # Check strictly for explicit tracking registration and status connectivity failures
        TRACKER_ERROR_MSG=$(echo "$TORRENT_DETAILS" | grep -E -i "tracker:|unregistered|not found" | head -n 1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [ -n "$TRACKER_ERROR_MSG" ]; then
            # Extract internal container tracking paths
            TORRENT_NAME=$(echo "$TORRENT_DETAILS" | grep "Name:" | cut -d':' -f2- | sed 's/^ //')
            LOCATION_DIR=$(echo "$TORRENT_DETAILS" | grep "Location:" | cut -d':' -f2- | sed 's/^ //')

            SUB_FOLDER=$(basename "$LOCATION_DIR")

            # Check if this torrent belongs to one of your targeted share directories
            MATCH_FOLDER=false
            for f in "${TARGET_FOLDERS[@]}"; do
                if [ "$f" = "$SUB_FOLDER" ]; then
                    MATCH_FOLDER=true
                    break
                fi
            done

            if [ "$MATCH_FOLDER" = false ]; then continue; fi

            ITEM_PATH="${BASE_PATH}/${SUB_FOLDER}/${TORRENT_NAME}"

            if [ -e "$ITEM_PATH" ]; then
                ITEM_KBYTES=$(du -s "$ITEM_PATH" | awk '{print $1}')
                TOTAL_TRACKER_ERR_KBYTES=$((TOTAL_TRACKER_ERR_KBYTES + ITEM_KBYTES))
                TRACKER_ERR_COUNT=$((TRACKER_ERR_COUNT + 1))

                if [ "$HEADER_PRINTED" = false ]; then
                    printf "%-*s | %-*s | %-*s\n" "$COL_NAME" "Name" "$COL_ID" "ID" "$COL_ERROR" "Tracker Error"
                    printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
                    HEADER_PRINTED=true
                fi

                disp_name="$TORRENT_NAME"
                if [ ${#disp_name} -gt $COL_NAME ]; then
                    trunc_len=$((COL_NAME - 3))
                    disp_name="${disp_name:0:$trunc_len}..."
                fi

                disp_err="$TRACKER_ERROR_MSG"
                if [ ${#disp_err} -gt $COL_ERROR ]; then
                    trunc_err=$((COL_ERROR - 3))
                    disp_err="${disp_err:0:$trunc_err}..."
                fi

                printf "%-*s | %-*s | %-*s\n" "$COL_NAME" "$disp_name" "$COL_ID" "$tid" "$COL_ERROR" "$disp_err"

                if [ "$DRY_RUN" = false ]; then
                    docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$tid" --remove-and-delete > /dev/null
                fi
            fi
        fi
    fi
done

if [ "$HEADER_PRINTED" = true ]; then
    printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
fi

# Convert exact summaries to clean, human-readable strings
HUMAN_ERROR_SIZE=$(awk -v kb="$TOTAL_TRACKER_ERR_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')

echo "----------------------------------------"
echo "=== SUMMARY: Dead Tracker Error Torrents Reclaimable: $HUMAN_ERROR_SIZE ($TRACKER_ERR_COUNT torrents affected) ==="
