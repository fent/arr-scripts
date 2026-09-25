#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: TRANSMISSION SEEDING ORPHANS PURGER (CASE A)
# ==============================================================================
# PURPOSE:
# This script identifies and removes active torrents that are currently seeding
# inside Transmission but have been upgraded or deleted from your Plex library.
#
# HOW IT WORKS:
# 1. It scans your media download directories (.tv, .movies, etc.) on disk.
# 2. It checks the Linux "Hard Link Count" for every media file found.
# 3. If a file has a Link Count of EXACTLY 1, it means the sorted companion file
#    inside your Plex library no longer exists (e.g., Sonarr/Radarr replaced it).
# 4. It cross-references that orphan file against Transmission's live manifest.
# 5. If the torrent meets EITHER of your safety thresholds (seeding for >= 30 days
#    OR has reached a >= 2.0 ratio), it tells Transmission to safely purge the
#    session memory and completely delete the duplicate files from your array.
#
# SAFETY GATES:
# Any active, wanted media files currently hard-linked to your library (Link Count >= 2)
# are completely skipped and protected from deletion, regardless of their age or ratio.
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

# Configurable Seeding Thresholds (Meeting EITHER parameter triggers deletion)
MIN_SEEDING_DAYS=30
MIN_RATIO="2.0"

# Media Extensions Filter
MEDIA_EXTS="mkv|mp4|avi|mov|wmv|flv|webm|ts|m4v"

echo "=== STARTING SEEDING ORPHANS CLEANUP ==="
echo "Dry Run Mode: $DRY_RUN"
echo "----------------------------------------"

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

RAW_MANIFEST=$(docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1)
TOTAL_ORPHAN_KBYTES=0
ORPHAN_COUNT=0

for folder in "${TARGET_FOLDERS[@]}"; do
    CURRENT_DIR="${BASE_PATH}/${folder}"
    if [ ! -d "$CURRENT_DIR" ]; then continue; fi
    echo "Scanning disk share: $CURRENT_DIR"

    while read -r -d $'\0' item_path; do
        ITEM_NAME=$(basename "$item_path")
        has_media=false
        still_linked=false

        if [ -d "$item_path" ]; then
            while read -r -d $'\0' media_file; do
                if echo "$(basename "$media_file")" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                    has_media=true
                    if [ "$(stat -c '%h' "$media_file")" -gt 1 ]; then
                        still_linked=true
                        break
                    fi
                fi
            done < <(find "$item_path" -type f -print0 2> /dev/null)
        else
            if echo "$ITEM_NAME" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                has_media=true
                if [ "$(stat -c '%h' "$item_path")" -gt 1 ]; then still_linked=true; fi
            fi
        fi

        if [ "$has_media" = false ] || [ "$still_linked" = true ]; then continue; fi

        TORRENT_ROW=""
        while read -r raw_row; do
            ROW_CLEAN=$(echo "$raw_row" | sed 's/ \+/ /g' | sed 's/^ //')
            LINE_NAME=$(echo "$ROW_CLEAN" | awk '{out=""; for(i=10;i<=NF;i++){out=out $i " "}; sub(/ $/,"",out); print out}')
            if [ "$LINE_NAME" = "$ITEM_NAME" ]; then
                TORRENT_ROW="$ROW_CLEAN"
                break
            fi
        done < <(echo "$RAW_MANIFEST" | grep -F "$ITEM_NAME")

        if [ -n "$TORRENT_ROW" ]; then
            TORRENT_ID=$(echo "$TORRENT_ROW" | cut -d' ' -f1 | tr -d '*')

            # FIXED: Added the proper block delimiters to the reverse row search pattern
            CURRENT_RATIO=$(echo "$TORRENT_ROW" | awk '{
                for(i=NF; i>1; i--) {
                    if($i ~ /^[0-9]+\.[0-9]+$/ || $i == "None") {
                        print $i;
                        exit
                    }
                }
            } END { print "0.0" }')

            if [[ "$CURRENT_RATIO" == "None" ]] || [[ ! "$CURRENT_RATIO" =~ ^[0-9.]+$ ]]; then CURRENT_RATIO="0.0"; fi

            ITEM_EPOCH=$(stat -c '%Y' "$item_path")
            NOW_EPOCH=$(date +%s)
            DAYS_SEEDING=$(((NOW_EPOCH - ITEM_EPOCH) / 86400))

            RATIO_PASS=$(awk -v r1="$CURRENT_RATIO" -v r2="$MIN_RATIO" 'BEGIN {print (r1 >= r2) ? 1 : 0}')

            if [ "$DAYS_SEEDING" -ge "$MIN_SEEDING_DAYS" ] || [ "$RATIO_PASS" -eq 1 ]; then
                ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
                TOTAL_ORPHAN_KBYTES=$((TOTAL_ORPHAN_KBYTES + ITEM_KBYTES))
                ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
                ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] Would purge orphan ($ITEM_HUMAN_SIZE): $ITEM_NAME (ID: $TORRENT_ID) | Ratio: $CURRENT_RATIO | Age: $DAYS_SEEDING days"
                else
                    echo "[ACTION] Purging orphan ($ITEM_HUMAN_SIZE): $ITEM_NAME"
                    docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$TORRENT_ID" --remove-and-delete > /dev/null
                fi
            fi
        fi
    done < <(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -print0)
done

HUMAN_ORPHAN_SIZE=$(awk -v kb="$TOTAL_ORPHAN_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
echo "----------------------------------------"
echo "=== SUMMARY: Seeding Orphans Reclaimable: $HUMAN_ORPHAN_SIZE ($ORPHAN_COUNT torrents affected) ==="
