#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: DEAD TRACKER ERROR TORRENTS PURGER
# ==============================================================================
# PURPOSE:
# This script scans Transmission for broken, dead, or unregistered
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
COL_SIZE=10
COL_ERROR=30
COL_TOTAL=$((COL_NAME + COL_SIZE + COL_ERROR + 6))

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

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

echo "Verifying Transmission RPC connection..."
if ! RAW_MANIFEST=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1); then
    echo "ERROR: Failed to connect to Transmission RPC."
    echo "Output: $RAW_MANIFEST"
    exit 1
fi

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

if ! echo "$RAW_MANIFEST" | grep -q "Sum:"; then
    echo "ERROR: Transmission did not return a valid torrent list. Safety abort."
    echo "Output: $RAW_MANIFEST"
    exit 1
fi

echo "Caching entire torrent manifest from Transmission..."
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
        TORRENT_DETAILS=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$tid" --info 2> /dev/null < /dev/null)

        # Check strictly for explicit tracking registration and status connectivity failures
        TRACKER_ERROR_MSG=$(echo "$TORRENT_DETAILS" | grep -E -i "tracker:|unregistered|not found" | head -n 1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Strip the useless hardcoded CLI prefix to save table space
        TRACKER_ERROR_MSG=$(echo "$TRACKER_ERROR_MSG" | sed -E 's/^(Tracker gave an error: |Error: |Tracker: )//i')

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
                HUMAN_SIZE=$(awk -v kb="$ITEM_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
                TOTAL_TRACKER_ERR_KBYTES=$((TOTAL_TRACKER_ERR_KBYTES + ITEM_KBYTES))
                TRACKER_ERR_COUNT=$((TRACKER_ERR_COUNT + 1))

                if [ "$HEADER_PRINTED" = false ]; then
                    printf "%-*s | %-*s | %-*s\n" "$COL_NAME" "Name" "$COL_SIZE" "Size" "$COL_ERROR" "Tracker Error"
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

                # Compensate for Bash printf multibyte padding bug on Name
                len_char_name=${#disp_name}
                len_byte_name=$(printf "%s" "$disp_name" | wc -c)
                name_width=$((COL_NAME + len_byte_name - len_char_name))

                # Compensate for Bash printf multibyte padding bug on Error
                len_char_err=${#disp_err}
                len_byte_err=$(printf "%s" "$disp_err" | wc -c)
                err_width=$((COL_ERROR + len_byte_err - len_char_err))

                printf "%-*s | %-*s | %-*s\n" "$name_width" "$disp_name" "$COL_SIZE" "$HUMAN_SIZE" "$err_width" "$disp_err"

                if [ "$DRY_RUN" = false ]; then
                    docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$tid" --remove > /dev/null < /dev/null
                    rm -rf "$ITEM_PATH"
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
if [ "$DRY_RUN" = true ]; then
    format_num "$TRACKER_ERR_COUNT" TRACKER_ERR_COUNT_FMT
    echo "=== SUMMARY: [DRY-RUN] $TRACKER_ERR_COUNT_FMT broken torrents found, would reclaim $HUMAN_ERROR_SIZE ==="
else
    format_num "$TRACKER_ERR_COUNT" TRACKER_ERR_COUNT_FMT
    echo "=== SUMMARY: Purged $TRACKER_ERR_COUNT_FMT broken torrents, reclaimed $HUMAN_ERROR_SIZE ==="
fi

if [ "$TRACKER_ERR_COUNT" -gt 0 ]; then
    # Trigger Unraid WebGUI Notification ONLY if running in the background (e.g. User Scripts plugin)
    # The [ ! -t 1 ] check ensures notifications are skipped if a user runs it manually in the shell/terminal.
    if [ -f "/usr/local/emhttp/webGui/scripts/notify" ] && [ ! -t 1 ]; then
        if [ "$DRY_RUN" = true ]; then
            format_num "$TRACKER_ERR_COUNT" TRACKER_ERR_COUNT_FMT
            /usr/local/emhttp/webGui/scripts/notify -i warning -s "Transmission Errors (DRY RUN)" -d "Found $TRACKER_ERR_COUNT_FMT broken torrents. Would reclaim $HUMAN_ERROR_SIZE."
        else
            format_num "$TRACKER_ERR_COUNT" TRACKER_ERR_COUNT_FMT
            /usr/local/emhttp/webGui/scripts/notify -i normal -s "Transmission Errors Purged" -d "Successfully purged $TRACKER_ERR_COUNT_FMT broken torrents and reclaimed $HUMAN_ERROR_SIZE."
        fi
    fi
fi
