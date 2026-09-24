#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                     # Set to 'false' to actively delete from Transmission and disk
CONTAINER_NAME="transmission"     # Name of your Transmission Docker container
BASE_PATH="/mnt/user/downloads"   # Parent path where your source folders live

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

echo "=== STARTING TRANSMISSION PATH-BASED & TRACKER ERROR PURGER ==="
echo "Dry Run Mode: $DRY_RUN"
echo "Required Seeding Metrics: >= $MIN_SEEDING_DAYS Days OR >= $MIN_RATIO Ratio"
echo "----------------------------------------"

AUTH_FLAG=""
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_FLAG="--auth ${TR_USER}:${TR_PASS}"
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

echo "Caching entire torrent manifest from Transmission..."
RAW_MANIFEST=$(docker exec -i "$CONTAINER_NAME" transmission-remote $AUTH_FLAG --list 2>&1)

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

# FIXED: Optimized Pre-Cache Tracker Error Scanner.
# Instead of guessing column text shifts, it pulls the individual details for the active IDs
# and checks if Transmission flags them internally with unregistered or tracker errors.
echo "Scanning for dead tracker states in database..."
ERROR_IDS=""
ALL_IDS=$(echo "$RAW_MANIFEST" | tail -n +2 | head -n -1 | awk '{print $1}' | tr -d '*')

for tid in $ALL_IDS; do
    if [[ "$tid" =~ ^[0-9]+$ ]]; then
        # Check if the specific torrent has tracking errors or registration messages logged
        error_check=$(docker exec -i "$CONTAINER_NAME" transmission-remote $AUTH_FLAG -t "$tid" --info 2>/dev/null | grep -E -i "tracker:|unregistered|not found")
        if [ -n "$error_check" ]; then
            ERROR_IDS="${ERROR_IDS}${tid} "
        fi
    fi
done

# Clean, in-memory trackers
TOTAL_ORPHAN_KBYTES=0
TOTAL_UNREFERENCED_KBYTES=0
TOTAL_TRACKER_ERR_KBYTES=0

ORPHAN_COUNT=0
UNREF_COUNT=0
TRACKER_ERR_COUNT=0

MET_AGE_COUNT=0
MET_RATIO_COUNT=0
MET_BOTH_COUNT=0

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
                    link_count=$(stat -c '%h' "$media_file")
                    if [ "$link_count" -gt 1 ]; then
                        still_linked=true
                        break
                    fi
                fi
            done < <(find "$item_path" -type f -print0 2>/dev/null)
        else
            if echo "$ITEM_NAME" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                has_media=true
                link_count=$(stat -c '%h' "$item_path")
                if [ "$link_count" -gt 1 ]; then
                    still_linked=true
                fi
            fi
        fi

        if [ "$has_media" = false ] && [ ! -d "$item_path" ]; then
            continue
        fi

        # Match using the full filename string layout against the cached list
        TORRENT_ROW=""
        while read -r raw_row; do
            ROW_CLEAN=$(echo "$raw_row" | sed 's/ \+/ /g' | sed 's/^ //')
            LINE_NAME=$(echo "$ROW_CLEAN" | awk '{out=""; for(i=10;i<=NF;i++){out=out $i " "}; sub(/ $/,"",out); print out}')

            if [ "$LINE_NAME" = "$ITEM_NAME" ]; then
                TORRENT_ROW="$ROW_CLEAN"
                break
            fi
        done < <(echo "$RAW_MANIFEST" | grep -F "$ITEM_NAME")

        # CASE A & C: Torrent matches an entry inside Transmission memory
        if [ -n "$TORRENT_ROW" ]; then
            TORRENT_ID=$(echo "$TORRENT_ROW" | cut -d' ' -f1 | tr -d '*')

            # -----------------------------------------------------------------
            # CASE C: TRACKER ERROR DETECTED (Purge instantly regardless of metrics)
            # -----------------------------------------------------------------
            if [[ " ${ERROR_IDS} " =~ " ${TORRENT_ID} " ]]; then
                ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
                TOTAL_TRACKER_ERR_KBYTES=$((TOTAL_TRACKER_ERR_KBYTES + ITEM_KBYTES))
                TRACKER_ERR_COUNT=$((TRACKER_ERR_COUNT + 1))

                ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

                if [ "$DRY_RUN" = true ]; then
                    echo "[DRY-RUN] -> DEAD TRACKER ERROR DETECTED: Would purge ($ITEM_HUMAN_SIZE): $ITEM_NAME (ID: $TORRENT_ID)"
                else
                    echo "[ACTION] -> Purging dead tracker torrent ($ITEM_HUMAN_SIZE): $ITEM_NAME (ID: $TORRENT_ID)"
                    docker exec -i "$CONTAINER_NAME" transmission-remote $AUTH_FLAG -t "$TORRENT_ID" --remove-and-delete > /dev/null
                fi
                continue
            fi

            # -----------------------------------------------------------------
            # CASE A: SEED LIMIT EVALUATION (Standard Orphans Engine)
            # -----------------------------------------------------------------
            if [ "$has_media" = true ] && [ "$still_linked" = false ]; then

                CURRENT_RATIO=$(echo "$TORRENT_ROW" | awk '{
                    for(i=NF; i>1; i--) {
                        if($i ~ /^[0-9]+\.[0-9]+$/ || $i == "None") {
                            print $i;
                            exit;
                        }
                    }
                    print "0.0";
                }')

                if [[ "$CURRENT_RATIO" == "None" ]] || [[ ! "$CURRENT_RATIO" =~ ^[0-9.]+$ ]]; then
                    CURRENT_RATIO="0.0"
                fi

                ITEM_EPOCH=$(stat -c '%Y' "$item_path")
                NOW_EPOCH=$(date +%s)
                DAYS_SEEDING=$(( (NOW_EPOCH - ITEM_EPOCH) / 86400 ))

                met_age=0
                met_ratio=0

                if [ "$DAYS_SEEDING" -ge "$MIN_SEEDING_DAYS" ]; then
                    met_age=1
                fi

                RATIO_PASS=$(awk -v r1="$CURRENT_RATIO" -v r2="$MIN_RATIO" 'BEGIN {print (r1 >= r2) ? 1 : 0}')
                if [ "$RATIO_PASS" -eq 1 ]; then
                    met_ratio=1
                fi

                if [ "$met_age" -eq 1 ] || [ "$met_ratio" -eq 1 ]; then
                    ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
                    TOTAL_ORPHAN_KBYTES=$((TOTAL_ORPHAN_KBYTES + ITEM_KBYTES))
                    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))

                    if [ "$met_age" -eq 1 ] && [ "$met_ratio" -eq 1 ]; then
                        MET_BOTH_COUNT=$((MET_BOTH_COUNT + 1))
                    elif [ "$met_age" -eq 1 ]; then
                        MET_AGE_COUNT=$((MET_AGE_COUNT + 1))
                    else
                        MET_RATIO_COUNT=$((MET_RATIO_COUNT + 1))
                    fi

                    ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

                    if [ "$DRY_RUN" = true ]; then
                        echo "[DRY-RUN] -> SEED LIMIT MET: Would purge torrent ($ITEM_HUMAN_SIZE): $ITEM_NAME (ID: $TORRENT_ID) | Ratio: $CURRENT_RATIO | Age: $DAYS_SEEDING days"
                    else
                        echo "[ACTION] -> Purging torrent ($ITEM_HUMAN_SIZE): $ITEM_NAME (ID: $TORRENT_ID) | Ratio: $CURRENT_RATIO | Age: $DAYS_SEEDING days"
                        docker exec -i "$CONTAINER_NAME" transmission-remote $AUTH_FLAG -t "$TORRENT_ID" --remove-and-delete > /dev/null
                    fi
                fi
            fi
        # CASE B: Ghost item on disk with no tracking reference inside Transmission
        else
            ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
            TOTAL_UNREFERENCED_KBYTES=$((TOTAL_UNREFERENCED_KBYTES + ITEM_KBYTES))
            UNREF_COUNT=$((UNREF_COUNT + 1))

            ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

            if [ "$DRY_RUN" = true ]; then
                echo "[DRY-RUN] -> UNREFERENCED GHOST ITEM: Would delete from array ($ITEM_HUMAN_SIZE): $ITEM_NAME"
            else
                echo "[ACTION] -> Deleting unreferenced item ($ITEM_HUMAN_SIZE): $ITEM_NAME"
                rm -rf "$item_path"
            fi
        fi
    done < <(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -print0)
done

# Convert exact summaries to clean strings
HUMAN_ORPHAN_SIZE=$(awk -v kb="$TOTAL_ORPHAN_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
HUMAN_UNREF_SIZE=$(awk -v kb="$TOTAL_UNREFERENCED_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
HUMAN_ERROR_SIZE=$(awk -v kb="$TOTAL_TRACKER_ERR_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')

echo "----------------------------------------"
echo "=== AUDIT RECLAIM SUMMARY ==="
echo "   -> Seeding Orphans Reclaimable: $HUMAN_ORPHAN_SIZE ($ORPHAN_COUNT torrents affected)"
echo "        * Hitting Seeding Age Only (>= $MIN_SEEDING_DAYS Days): $MET_AGE_COUNT"
echo "        * Hitting Ratio Only (>= $MIN_RATIO): $MET_RATIO_COUNT"
echo "        * Hitting BOTH Requirements: $MET_BOTH_COUNT"
echo "   -> Dead Tracker Error Torrents Reclaimable: $HUMAN_ERROR_SIZE ($TRACKER_ERR_COUNT torrents affected)"
echo "   -> Dead Unreferenced Items Reclaimable: $HUMAN_UNREF_SIZE ($UNREF_COUNT items affected)"
echo "----------------------------------------"
