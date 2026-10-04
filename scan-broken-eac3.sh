#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: PLEX EAC3 CORRUPTION SCANNER
# ==============================================================================
# PURPOSE:
# Scans your entire Plex library for severely corrupted EAC3 (Dolby Digital Plus)
# audio tracks that cause the Plex EasyAudioEncoder (EAE) to hard-crash.
#
# HOW IT WORKS:
# 1. Queries the Plex SQLite database to find all EAC3 files (<= 6 channels).
# 2. Spawns an isolated instance of Plex's proprietary EAE transcoder engine.
# 3. Feeds 50 frames of each file directly into the engine.
# 4. If the engine spits out continuous "Cannot group in blocks of 6!" errors,
#    the file is flagged as corrupted and safely logged to broken-eac3-list.txt
#
# USAGE:
# Run normally: ./scan-broken-eac3.sh
# Resume scan:  ./scan-broken-eac3.sh --continue-from 4400
# ==============================================================================

START_AT=0
RECENT_HOURS=0

# Parse arguments for resume functionality
while [[ "$#" -gt 0 ]]; do
    case $1 in
    --continue-from)
        START_AT="$2"
        shift 2
        ;;
    --recent)
        RECENT_HOURS="$2"
        shift 2
        ;;
    *)
        echo "Unknown parameter: $1"
        echo "Usage: ./scan-broken-eac3.sh [--continue-from <number>] [--recent <hours>]"
        exit 1
        ;;
    esac
done

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

PLEX_CONT=$(docker ps --format '{{.Names}}' | grep -i plex | head -n 1)
if [ -z "$PLEX_CONT" ]; then
    echo "Error: Could not find a Plex docker container running."
    exit 1
fi
echo "Using Plex container: $PLEX_CONT"

echo "Dynamically locating Plex database..."
# 1. Check official Plex environment variable first
APP_SUPPORT=$(docker exec "$PLEX_CONT" sh -c 'echo $PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR')

if [ -n "$APP_SUPPORT" ] && docker exec "$PLEX_CONT" test -f "$APP_SUPPORT/Plug-in Support/Databases/com.plexapp.plugins.library.db"; then
    DB_INTERNAL_PATH="$APP_SUPPORT/Plug-in Support/Databases/com.plexapp.plugins.library.db"
# 2. Check standard Linuxserver / Official image path
elif docker exec "$PLEX_CONT" test -f "/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"; then
    DB_INTERNAL_PATH="/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
# 3. Check Binhex image path
elif docker exec "$PLEX_CONT" test -f "/config/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"; then
    DB_INTERNAL_PATH="/config/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
# 4. Check Hotio / Custom unRaid direct mapping
elif docker exec "$PLEX_CONT" test -f "/config/Plug-in Support/Databases/com.plexapp.plugins.library.db"; then
    DB_INTERNAL_PATH="/config/Plug-in Support/Databases/com.plexapp.plugins.library.db"
else
    # 5. Final safety fallback (ignore all backup variations)
    DB_INTERNAL_PATH=$(docker exec "$PLEX_CONT" find /config -maxdepth 5 -name "com.plexapp.plugins.library.db" -not -path "*[Bb]ackup*" 2> /dev/null | head -n 1)
fi

if [ -z "$DB_INTERNAL_PATH" ] || ! docker exec "$PLEX_CONT" test -f "$DB_INTERNAL_PATH"; then
    echo "Error: Could not locate com.plexapp.plugins.library.db inside the container."
    exit 1
fi

echo "Copying database to RAM ($DB_INTERNAL_PATH)..."
docker cp "$PLEX_CONT:$DB_INTERNAL_PATH" /tmp/plex_db_copy.db

# Build the time filter
if [ "$RECENT_HOURS" -gt 0 ]; then
    TIME_SEC=$((RECENT_HOURS * 3600))
    TIME_FILTER="AND metadata_items.added_at > (CAST(strftime('%s', 'now') AS INTEGER) - $TIME_SEC)"
    echo "Filtering database to EAC3 files added in the last $RECENT_HOURS hours..."
else
    TIME_FILTER=""
    echo "Querying database for all standard EAC3 files..."
fi

# Get all EAC3 files with 6 or fewer channels (Standard 5.1 and Stereo)
sqlite3 /tmp/plex_db_copy.db "
SELECT media_parts.file
FROM media_streams
JOIN media_parts ON media_streams.media_part_id = media_parts.id
JOIN media_items ON media_parts.media_item_id = media_items.id
JOIN metadata_items ON media_items.metadata_item_id = metadata_items.id
WHERE media_streams.stream_type_id = 2
  AND media_streams.codec = 'eac3'
  AND media_streams.channels <= 6
  $TIME_FILTER
GROUP BY media_parts.file
ORDER BY media_parts.id ASC;
" > /tmp/eac3-51-files.txt
rm /tmp/plex_db_copy.db

TOTAL_FILES=$(wc -l < /tmp/eac3-51-files.txt | tr -d ' ')
format_num "$TOTAL_FILES" TOTAL_FMT

echo "Found $TOTAL_FMT standard EAC3 files to test."

OUTPUT_FILE="$(pwd)/broken-eac3-list.txt"

# If we are starting from 0, clear the output file. Otherwise, append to it.
if [ "$START_AT" -eq 0 ]; then
    : > "$OUTPUT_FILE"
    echo "Starting deep scan from the beginning..."
else
    echo "Resuming scan from file #$START_AT. Appending to existing broken-eac3-list.txt..."
fi

COUNT=0
# If resuming, figure out how many broken files we already found so the counter isn't reset
if [ -f "$OUTPUT_FILE" ]; then
    BROKEN=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
else
    BROKEN=0
fi

echo "Setting up temporary EAE watchfolder inside container..."
docker exec "$PLEX_CONT" mkdir -p "/tmp/eae_test/Convert to WAV (to 8ch or less)"
docker exec "$PLEX_CONT" chmod -R 777 /tmp/eae_test

echo "Warning: This will wake up spun-down hard drives!"
echo "-----------------------------------------------------------------"

while IFS= read -r file; do
    COUNT=$((COUNT + 1))

    # Fast-forward until we hit our starting point
    if [ "$COUNT" -lt "$START_AT" ]; then
        # Just update the display quickly so the user knows it's skipping
        if [ $((COUNT % 500)) -eq 0 ]; then
            format_num "$COUNT" COUNT_FMT
            echo -ne "Skipping to $START_AT... currently at $COUNT_FMT \r"
        fi
        continue
    fi

    # Securely wipe and recreate the EAE watchfolder so the engine has a pristine environment
    docker exec "$PLEX_CONT" sh -c 'rm -rf "/tmp/eae_test"; mkdir -p "/tmp/eae_test/Convert to WAV (to 8ch or less)"; chmod -R 777 /tmp/eae_test'

    # Format counts for display
    format_num "$COUNT" COUNT_FMT
    format_num "$BROKEN" BROKEN_FMT

    # Print status (overwrites the line)
    echo -ne "Scanning $COUNT_FMT / $TOTAL_FMT  |  Corrupted: $BROKEN_FMT \r"

    ERR=$(docker exec "$PLEX_CONT" timeout 10 env EAE_ROOT=/tmp/eae_test /app/bin/usr/lib/plexmediaserver/Plex\ Transcoder -y -nostdin -v error -i "$file" -map 0:a:0 -frames:a 50 -f wav /dev/null 2>&1 < /dev/null)

    # Ignore "No such file" errors
    if echo "$ERR" | grep -q "No such file or directory"; then
        continue
    fi

    # Count how many bad blocks it hit
    ERROR_COUNT=$(echo "$ERR" | grep -c "Cannot group in blocks of 6!")

    # If it spewed continuous corruption errors (> 10)
    if [ "$ERROR_COUNT" -gt 10 ]; then
        echo -e "\n[CORRUPT] $file"
        echo "$file" >> "$OUTPUT_FILE"
        BROKEN=$((BROKEN + 1))
    fi

done < /tmp/eac3-51-files.txt

format_num "$BROKEN" BROKEN_FMT

echo -e "\n-----------------------------------------------------------------"
echo "Scan complete! Found a total of $BROKEN_FMT severely broken files."
echo "List saved to $OUTPUT_FILE"

# Trigger Unraid WebGUI Notification ONLY if running in the background (e.g. User Scripts plugin)
# The [ ! -t 1 ] check ensures notifications are skipped if a user runs it manually in the shell/terminal.
if [ -f "/usr/local/emhttp/webGui/scripts/notify" ] && [ ! -t 1 ]; then
    if [ "$BROKEN" -gt 0 ]; then
        /usr/local/emhttp/webGui/scripts/notify -i warning -s "Plex EAC3 Scan" -d "Found $BROKEN_FMT broken EAC3 files. See broken-eac3-list.txt for details."
    else
        /usr/local/emhttp/webGui/scripts/notify -i normal -s "Plex EAC3 Scan" -d "Daily scan complete. No broken files found."
    fi
fi
