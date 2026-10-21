#!/bin/bash
# ==============================================================================
# SCRIPT DESCRIPTION: FIX BROKEN AUDIO
# ==============================================================================
# PURPOSE:
#   Reads broken-eac3-list.txt, converts audio to AC3, and tells Plex to re-analyze.
#
# HOW IT WORKS:
#   1. Maps Plex container paths to Unraid host paths.
#   2. Iterates over the broken files list.
#   3. Converts the broken EAC3 audio track to AC3 using ffmpeg.
#   4. Replaces the original file and tells Plex to scan the updated file.
# ==============================================================================

# --- CONFIGURATION ---
DRY_RUN="${DRY_RUN:-true}" # Set to 'false' to actively convert files and update Plex
PLEX_CONT="plex"
LIST_FILE="broken-eac3-list.txt"

# PATH TRANSLATION:
# Map your Plex container paths to your Unraid host paths.
declare -A PATH_MAPPINGS=(
    ["/media"]="/mnt/user/downloads"
)
# ---------------------

if [ ! -f "$LIST_FILE" ]; then
    echo "Error: Could not find $LIST_FILE in the current directory."
    exit 1
fi

echo "=== STARTING FIX BROKEN AUDIO ==="
if [ "$DRY_RUN" = true ]; then
    echo "Dry Run Mode: $DRY_RUN"
fi
echo "----------------------------------------"

# Create a temporary copy to iterate over so we can safely modify the original in-place
cp "$LIST_FILE" "${LIST_FILE}.run"

while IFS= read -r PLEX_PATH; do
    # Skip empty lines
    [ -z "$PLEX_PATH" ] && continue

    # Translate the path from Plex's perspective to the Unraid Host's perspective
    HOST_PATH="$PLEX_PATH"
    for plex_mnt in "${!PATH_MAPPINGS[@]}"; do
        host_mnt="${PATH_MAPPINGS[$plex_mnt]}"
        if [[ "$PLEX_PATH" == "$plex_mnt"* ]]; then
            HOST_PATH="${PLEX_PATH/#$plex_mnt/$host_mnt}"
            break
        fi
    done

    if [ ! -f "$HOST_PATH" ]; then
        echo "[x] Skipped: File not found on host (Check path translation!): $HOST_PATH"
        continue
    fi

    echo "[*] Processing: $(basename "$HOST_PATH")"

    if [ "$DRY_RUN" = false ]; then
        TMP_FILE="${HOST_PATH}.tmp.mkv"

        # Run FFmpeg (Copy Video, Copy Subtitles, Convert Audio to AC3 5.1 640k)
        # Using -nostdin to prevent ffmpeg from swallowing loop input
        if ffmpeg -nostdin -y -v error -stats -i "$HOST_PATH" -map 0 -c:v copy -c:s copy -c:a ac3 -b:a 640k "$TMP_FILE" && [ -f "$TMP_FILE" ]; then
            # Swap the fixed file into place
            mv "$TMP_FILE" "$HOST_PATH"
            chmod 0666 "$HOST_PATH"

            echo "[✓] Converted successfully. Instructing Plex to re-analyze..."

            # Trigger Plex Media Scanner inside the container to update the database
            docker exec "$PLEX_CONT" /usr/lib/plexmediaserver/Plex\ Media\ Scanner --analyze --file "$PLEX_PATH" > /dev/null 2>&1

            # Safely remove the file from the original list so it can resume cleanly if interrupted
            sed -i '' "\|${PLEX_PATH}|d" "$LIST_FILE" 2> /dev/null || sed -i "\|${PLEX_PATH}|d" "$LIST_FILE"
        else
            echo "[x] FFmpeg failed on $HOST_PATH. Deleting corrupt temp file."
            rm -f "$TMP_FILE"
        fi
    fi

    echo "--------------------------------------------------------"
done < "${LIST_FILE}.run"

# Cleanup the iteration file
rm -f "${LIST_FILE}.run"

echo "All Done!"
