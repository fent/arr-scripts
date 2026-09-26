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

# Table Formatting
COL_NAME=85
COL_SIZE=10
COL_RATIO=8
COL_AGE=8
COL_TOTAL=$((COL_NAME + COL_SIZE + COL_RATIO + COL_AGE + 9)) # 9 chars for separators

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

RAW_MANIFEST=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1)
TOTAL_ORPHAN_KBYTES=0
ORPHAN_COUNT=0
MATCHED_RATIO_COUNT=0
MATCHED_AGE_COUNT=0
MATCHED_BOTH_COUNT=0

for folder in "${TARGET_FOLDERS[@]}"; do
    CURRENT_DIR="${BASE_PATH}/${folder}"
    if [ ! -d "$CURRENT_DIR" ]; then continue; fi

    echo "Scanning disk share: $CURRENT_DIR"
    HEADER_PRINTED=false

    while read -r -d $'\0' item_path; do
        ITEM_NAME=$(basename "$item_path")
        still_linked=false

        if [ -d "$item_path" ]; then
            while read -r -d $'\0' file_in_folder; do
                if [ "$(stat -c '%h' "$file_in_folder")" -gt 1 ]; then
                    still_linked=true
                    break
                fi
            done < <(find "$item_path" -type f -print0 2> /dev/null)
        else
            if [ "$(stat -c '%h' "$item_path")" -gt 1 ]; then
                still_linked=true
            fi
        fi

        if [ "$still_linked" = true ]; then continue; fi

        TORRENT_ROW=""
        while read -r raw_row; do
            ROW_CLEAN=$(echo "$raw_row" | awk '{$1=$1};1')
            if [[ "$ROW_CLEAN" == *" $ITEM_NAME" ]]; then
                TORRENT_ROW="$ROW_CLEAN"
                break
            fi
        done < <(echo "$RAW_MANIFEST" | grep -F "$ITEM_NAME")

        if [ -n "$TORRENT_ROW" ]; then
            TORRENT_ID=$(echo "$TORRENT_ROW" | cut -d' ' -f1 | tr -d '*')

            # ROBUST RATIO EXTRACTION: Strip the literal name off the row first, then scan backwards.
            # This completely guarantees we don't accidentally parse a ratio-like number inside the torrent's name.
            ROW_NO_NAME=${TORRENT_ROW% $ITEM_NAME}
            CURRENT_RATIO=$(echo "$ROW_NO_NAME" | awk '{
                found=0;
                for(i=NF; i>1; i--) {
                    if($i ~ /^[0-9]+\.[0-9]+$/ || $i == "None") {
                        print $i;
                        found=1;
                        exit
                    }
                }
            } END { if(!found) print "0.00" }')

            if [[ "$CURRENT_RATIO" == "None" ]] || [[ ! "$CURRENT_RATIO" =~ ^[0-9.]+$ ]]; then
                CURRENT_RATIO="0.00"
            else
                CURRENT_RATIO=$(printf "%.2f" "$CURRENT_RATIO")
            fi

            ITEM_EPOCH=$(stat -c '%Y' "$item_path")
            NOW_EPOCH=$(date +%s)
            DAYS_SEEDING=$(((NOW_EPOCH - ITEM_EPOCH) / 86400))

            RATIO_PASS=$(awk -v r1="$CURRENT_RATIO" -v r2="$MIN_RATIO" 'BEGIN {print (r1 >= r2) ? 1 : 0}')

            if [ "$DAYS_SEEDING" -ge "$MIN_SEEDING_DAYS" ] || [ "$RATIO_PASS" -eq 1 ]; then

                if [ "$RATIO_PASS" -eq 1 ] && [ "$DAYS_SEEDING" -ge "$MIN_SEEDING_DAYS" ]; then
                    MATCHED_BOTH_COUNT=$((MATCHED_BOTH_COUNT + 1))
                elif [ "$RATIO_PASS" -eq 1 ]; then
                    MATCHED_RATIO_COUNT=$((MATCHED_RATIO_COUNT + 1))
                else
                    MATCHED_AGE_COUNT=$((MATCHED_AGE_COUNT + 1))
                fi

                ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
                TOTAL_ORPHAN_KBYTES=$((TOTAL_ORPHAN_KBYTES + ITEM_KBYTES))
                ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
                ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

                if [ "$HEADER_PRINTED" = false ]; then
                    printf "%-*s | %-*s | %-*s | %-*s\n" "$COL_NAME" "Name" "$COL_SIZE" "Size" "$COL_RATIO" "Ratio" "$COL_AGE" "Age"
                    printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
                    HEADER_PRINTED=true
                fi

                disp_name="$ITEM_NAME"
                if [ ${#disp_name} -gt $COL_NAME ]; then
                    trunc_len=$((COL_NAME - 3))
                    disp_name="${disp_name:0:$trunc_len}..."
                fi

                # Compensate for Bash printf multibyte padding bug
                len_char=${#disp_name}
                len_byte=$(printf "%s" "$disp_name" | wc -c)
                name_width=$((COL_NAME + len_byte - len_char))

                printf "%-*s | %-*s | %-*s | %-*s\n" "$name_width" "$disp_name" "$COL_SIZE" "$ITEM_HUMAN_SIZE" "$COL_RATIO" "$CURRENT_RATIO" "$COL_AGE" "${DAYS_SEEDING}d"

                if [ "$DRY_RUN" = false ]; then
                    docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t "$TORRENT_ID" --remove > /dev/null < /dev/null
                    rm -rf "$item_path"
                fi
            fi
        fi
    done < <(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -print0)

    if [ "$HEADER_PRINTED" = true ]; then
        printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
    fi
done

HUMAN_ORPHAN_SIZE=$(awk -v kb="$TOTAL_ORPHAN_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')

if [ "$DRY_RUN" = true ]; then
    echo "=== SUMMARY: [DRY-RUN] $ORPHAN_COUNT orphans found, would reclaim $HUMAN_ORPHAN_SIZE ==="
else
    echo "=== SUMMARY: Purged $ORPHAN_COUNT orphans, reclaimed $HUMAN_ORPHAN_SIZE ==="
fi
if [ "$ORPHAN_COUNT" -gt 0 ]; then
    echo "    - Matched Ratio limit (>= $MIN_RATIO): $MATCHED_RATIO_COUNT"
    echo "    - Matched Time limit (>= ${MIN_SEEDING_DAYS}d): $MATCHED_AGE_COUNT"
    if [ "$MATCHED_BOTH_COUNT" -gt 0 ]; then
        echo "    - Matched Both limits: $MATCHED_BOTH_COUNT"
    fi
fi
