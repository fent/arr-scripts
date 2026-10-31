#!/bin/bash
# ==============================================================================
# SCRIPT DESCRIPTION: FIX BROKEN AUDIO & NOTIFY ARR / PLEX
# ==============================================================================
# PURPOSE:
#   Reads broken-eac3-list.txt, converts audio to AC3, notifies Radarr or Sonarr
#   to rescan and rename if necessary, and instructs Plex to re-analyze.
#
# HOW IT WORKS:
#   1. Maps Plex container paths to Unraid host paths (auto-detecting mounts).
#   2. Iterates over the broken files list.
#   3. Converts the broken EAC3 audio track to AC3 using host ffmpeg or Docker.
#   4. Replaces the original file.
#   5. Notifies Radarr or Sonarr to rescan and rename the file if applicable.
#   6. Instructs Plex to scan the directory and re-analyze the media.
#   7. Removes the fixed file from broken-eac3-list.txt and logs to fixed-eac3-list.txt.
# ==============================================================================

# --- CONFIGURATION ---
DRY_RUN="${DRY_RUN:-true}" # Set to 'false' to actively convert files and update Plex/Radarr/Sonarr
PLEX_CONT="${PLEX_CONT:-plex}"
LIST_FILE="${LIST_FILE:-broken-eac3-list.txt}"
FIXED_FILE="${FIXED_FILE:-fixed-eac3-list.txt}"
FFMPEG_IMAGE="${FFMPEG_IMAGE:-linuxserver/ffmpeg}" # Docker image used when ffmpeg is not installed on the host

# Radarr Integration
UPDATE_RADARR="${UPDATE_RADARR:-true}"            # Set to 'true' to notify Radarr when a movie file is fixed
RADARR_URL="${RADARR_URL:-http://localhost:7878}" # Radarr base URL
RADARR_API_KEY="${RADARR_API_KEY:-}"              # Leave empty to auto-detect from RADARR_CONFIG
RADARR_CONFIG="${RADARR_CONFIG:-/mnt/user/appdata/radarr/config.xml}"

# Sonarr Integration
UPDATE_SONARR="${UPDATE_SONARR:-true}"            # Set to 'true' to notify Sonarr when an episode file is fixed
SONARR_URL="${SONARR_URL:-http://localhost:8989}" # Sonarr base URL
SONARR_API_KEY="${SONARR_API_KEY:-}"              # Leave empty to auto-detect from SONARR_CONFIG
SONARR_CONFIG="${SONARR_CONFIG:-/mnt/user/appdata/sonarr/config.xml}"

# PATH TRANSLATION:
# Map your Plex container paths to your Unraid host paths.
# (Any unmapped paths will also be auto-detected from Plex container mounts)
declare -A PATH_MAPPINGS=(
    ["/media"]="/mnt/user/data/media"
)
# ---------------------

if ! docker ps --format '{{.Names}}' | grep -q "^${PLEX_CONT}$"; then
    echo "Error: Docker container '${PLEX_CONT}' is not running."
    exit 1
fi

# Locate Plex binaries inside the container (supports Hotio, Official, LinuxServer, Binhex)
if docker exec "$PLEX_CONT" test -f "/app/bin/usr/lib/plexmediaserver/Plex Media Scanner"; then
    PLEX_BIN_DIR="/app/bin/usr/lib/plexmediaserver"
else
    PLEX_BIN_DIR="/usr/lib/plexmediaserver"
fi

# Detect Plex application support directory inside the container
PLEX_APP_SUPPORT=$(docker exec "$PLEX_CONT" sh -c 'PID=$(pidof "Plex Media Server" 2>/dev/null | awk "{print \$1}"); [ -n "$PID" ] && tr "\0" "\n" < "/proc/$PID/environ" 2>/dev/null | sed -n "s/^PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=//p"' 2> /dev/null)
if [ -z "$PLEX_APP_SUPPORT" ]; then
    if docker exec "$PLEX_CONT" test -d "/app/config/Plex Media Server"; then
        PLEX_APP_SUPPORT="/app/config"
    elif docker exec "$PLEX_CONT" test -d "/config/Library/Application Support/Plex Media Server"; then
        PLEX_APP_SUPPORT="/config/Library/Application Support"
    else
        PLEX_APP_SUPPORT="/config"
    fi
fi

# Auto-populate PATH_MAPPINGS from docker inspect mounts as fallback
while IFS='|' read -r dst src; do
    if [ -n "$dst" ] && [ -n "$src" ] && [ -z "${PATH_MAPPINGS[$dst]+_}" ]; then
        PATH_MAPPINGS["$dst"]="$src"
    fi
done < <(docker inspect "$PLEX_CONT" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2> /dev/null)

# Prepare FFmpeg
HAS_HOST_FFMPEG=false
if command -v ffmpeg > /dev/null 2>&1; then
    HAS_HOST_FFMPEG=true
    echo "Using host ffmpeg: $(command -v ffmpeg)"
else
    echo "Host ffmpeg not found; using Docker image: $FFMPEG_IMAGE"
    if [ "$DRY_RUN" = true ]; then
        echo "Dry run: skipping Docker image pull."
    elif ! docker image inspect "$FFMPEG_IMAGE" > /dev/null 2>&1; then
        echo "Pulling $FFMPEG_IMAGE image..."
        docker pull "$FFMPEG_IMAGE" > /dev/null
    fi
fi

# Prepare Radarr and Sonarr API keys
if [ "$UPDATE_RADARR" = true ] && [ -z "$RADARR_API_KEY" ] && [ -f "$RADARR_CONFIG" ]; then
    RADARR_API_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$RADARR_CONFIG" | tr -d '[:space:]')
fi
if [ "$UPDATE_RADARR" = true ]; then
    if [ -n "$RADARR_API_KEY" ]; then
        echo "Radarr integration: enabled ($RADARR_URL)"
    else
        echo "Warning: UPDATE_RADARR is true but no RADARR_API_KEY was found. Skipping Radarr updates."
        UPDATE_RADARR=false
    fi
fi

if [ "$UPDATE_SONARR" = true ] && [ -z "$SONARR_API_KEY" ] && [ -f "$SONARR_CONFIG" ]; then
    SONARR_API_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$SONARR_CONFIG" | tr -d '[:space:]')
fi
if [ "$UPDATE_SONARR" = true ]; then
    if [ -n "$SONARR_API_KEY" ]; then
        echo "Sonarr integration: enabled ($SONARR_URL)"
    else
        echo "Warning: UPDATE_SONARR is true but no SONARR_API_KEY was found. Skipping Sonarr updates."
        UPDATE_SONARR=false
    fi
fi

# Translate a Plex container path to an Unraid host path
translate_plex_to_host() {
    local plex_path="$1"
    local host_path="$plex_path"
    local best_len=0
    local plex_mnt host_mnt
    for plex_mnt in "${!PATH_MAPPINGS[@]}"; do
        host_mnt="${PATH_MAPPINGS[$plex_mnt]}"
        if [[ "$plex_path" == "$plex_mnt"/* ]] || [[ "$plex_path" == "$plex_mnt" ]]; then
            if [ "${#plex_mnt}" -gt "$best_len" ]; then
                best_len="${#plex_mnt}"
                host_path="${plex_path/#$plex_mnt/$host_mnt}"
            fi
        fi
    done
    printf "%s" "$host_path"
}

# Translate an Unraid host path back to a Plex container path
translate_host_to_plex() {
    local host_path="$1"
    local plex_path="$host_path"
    local best_len=0
    local plex_mnt host_mnt
    for plex_mnt in "${!PATH_MAPPINGS[@]}"; do
        host_mnt="${PATH_MAPPINGS[$plex_mnt]}"
        if [[ "$host_path" == "$host_mnt"/* ]] || [[ "$host_path" == "$host_mnt" ]]; then
            if [ "${#host_mnt}" -gt "$best_len" ]; then
                best_len="${#host_mnt}"
                plex_path="${host_path/#$host_mnt/$plex_mnt}"
            fi
        fi
    done
    printf "%s" "$plex_path"
}

# Run ffmpeg either natively on host or via Docker container
run_ffmpeg() {
    local host_dir="$1"
    shift
    if [ "$HAS_HOST_FFMPEG" = true ]; then
        ffmpeg "$@"
    else
        docker run --rm -i -v "${host_dir}:${host_dir}" "$FFMPEG_IMAGE" "$@"
    fi
}

# Wait briefly for a queued Radarr/Sonarr command to complete
wait_arr_command() {
    local base_url="$1"
    local api_key="$2"
    local cmd_id="$3"
    [ -z "$cmd_id" ] || [ "$cmd_id" = "null" ] && return 0
    local _ status
    for _ in {1..15}; do
        status=$(curl -s -H "X-Api-Key: $api_key" "${base_url}/api/v3/command/${cmd_id}" | jq -r '.status // empty' 2> /dev/null)
        if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
            break
        fi
        sleep 1
    done
}

# Notify Radarr about the modified movie file so it rescans MediaInfo and renames if needed
# Returns 0 if handled by Radarr, 1 if movie was not found in Radarr.
update_radarr_movie() {
    local host_path="$1"
    UPDATED_HOST_PATH="$host_path"
    [ "$UPDATE_RADARR" != true ] && return 1

    local movie_id=""
    local tmdb_id=""

    # 1. Try matching by {tmdb-ID} in folder/file path
    if [[ "$host_path" =~ \{tmdb-([0-9]+)\} ]]; then
        tmdb_id="${BASH_REMATCH[1]}"
        movie_id=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" "${RADARR_URL}/api/v3/movie?tmdbId=${tmdb_id}" | jq -r '.[0].id // empty' 2> /dev/null)
    fi

    # 2. Fallback to Radarr parse endpoint using filename
    if [ -z "$movie_id" ]; then
        local base_name
        base_name=$(basename "$host_path")
        movie_id=$(curl -s -G -H "X-Api-Key: $RADARR_API_KEY" --data-urlencode "title=${base_name}" "${RADARR_URL}/api/v3/parse" | jq -r '.movie.id // empty' 2> /dev/null)
    fi

    if [ -z "$movie_id" ] || [ "$movie_id" = "null" ]; then
        return 1
    fi

    # Radarr skips re-running MediaInfo on RescanMovie if the filename on disk is identical
    # to the existing MovieFile record. Temporarily staging or renaming forces Radarr to
    # re-import and refresh MediaInfo (updating EAC3 -> AC3).
    local dir_name base_name new_base_name staged_path
    dir_name=$(dirname "$host_path")
    base_name=$(basename "$host_path")

    # Replace EAC3/DDP tokens in the filename with AC3/DD if present; otherwise use a temporary stage name
    new_base_name=$(echo "$base_name" | sed -E 's/E-?AC-?3/AC3/Ig; s/DDP/DD/g; s/DD\+/DD/g')
    if [ "$new_base_name" != "$base_name" ]; then
        staged_path="${dir_name}/${new_base_name}"
        mv "$host_path" "$staged_path"
        UPDATED_HOST_PATH="$staged_path"
    else
        # No codec token in filename: briefly rescan while hidden so Radarr drops stale MediaInfo
        staged_path="${host_path}.radarr_rescan_tmp"
        mv "$host_path" "$staged_path"
        local drop_cmd
        drop_cmd=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
            -X POST "${RADARR_URL}/api/v3/command" \
            -d "{\"name\":\"RescanMovie\",\"movieId\":${movie_id}}" | jq -r '.id // empty' 2> /dev/null)
        wait_arr_command "$RADARR_URL" "$RADARR_API_KEY" "$drop_cmd"
        mv "$staged_path" "$host_path"
        UPDATED_HOST_PATH="$host_path"
    fi

    echo "    [*] Radarr: Triggering RescanMovie (ID: $movie_id)..."
    local cmd_id
    cmd_id=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
        -X POST "${RADARR_URL}/api/v3/command" \
        -d "{\"name\":\"RescanMovie\",\"movieId\":${movie_id}}" | jq -r '.id // empty' 2> /dev/null)
    wait_arr_command "$RADARR_URL" "$RADARR_API_KEY" "$cmd_id"

    # Check if Radarr wants to standardize the filename according to its naming format
    local rename_ids
    rename_ids=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" "${RADARR_URL}/api/v3/rename?movieId=${movie_id}" | jq -c '[.[].movieFileId] // []' 2> /dev/null)
    if [ -n "$rename_ids" ] && [ "$rename_ids" != "[]" ] && [ "$rename_ids" != "null" ]; then
        echo "    [*] Radarr: Renaming file to match new MediaInfo..."
        local rename_cmd
        rename_cmd=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" -H "Content-Type: application/json" \
            -X POST "${RADARR_URL}/api/v3/command" \
            -d "{\"name\":\"RenameFiles\",\"movieId\":${movie_id},\"files\":${rename_ids}}" | jq -r '.id // empty' 2> /dev/null)
        wait_arr_command "$RADARR_URL" "$RADARR_API_KEY" "$rename_cmd"
    fi

    # Query Radarr for the current movieFile path in case it renamed the file
    local radarr_rel_path
    radarr_rel_path=$(curl -s -H "X-Api-Key: $RADARR_API_KEY" "${RADARR_URL}/api/v3/movie/${movie_id}" | jq -r '.movieFile.relativePath // empty' 2> /dev/null)
    if [ -n "$radarr_rel_path" ] && [ -f "${dir_name}/${radarr_rel_path}" ]; then
        UPDATED_HOST_PATH="${dir_name}/${radarr_rel_path}"
    fi
    echo "    [✔] Radarr: Movie updated ($(basename "$UPDATED_HOST_PATH"))."
    return 0
}

# Notify Sonarr about the modified episode file so it rescans MediaInfo and renames if needed
# Returns 0 if handled by Sonarr, 1 if series was not found in Sonarr.
update_sonarr_episode() {
    local host_path="$1"
    UPDATED_HOST_PATH="$host_path"
    [ "$UPDATE_SONARR" != true ] && return 1

    local series_id=""
    local tvdb_id=""

    # 1. Try matching by {tvdb-ID} in folder/file path
    if [[ "$host_path" =~ \{tvdb-([0-9]+)\} ]]; then
        tvdb_id="${BASH_REMATCH[1]}"
        series_id=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" "${SONARR_URL}/api/v3/series?tvdbId=${tvdb_id}" | jq -r '.[0].id // empty' 2> /dev/null)
    fi

    # 2. Fallback to Sonarr parse endpoint using filename
    if [ -z "$series_id" ]; then
        local base_name
        base_name=$(basename "$host_path")
        series_id=$(curl -s -G -H "X-Api-Key: $SONARR_API_KEY" --data-urlencode "title=${base_name}" "${SONARR_URL}/api/v3/parse" | jq -r '.series.id // empty' 2> /dev/null)
    fi

    if [ -z "$series_id" ] || [ "$series_id" = "null" ]; then
        return 1
    fi

    # Sonarr skips re-running MediaInfo on RescanSeries if the filename on disk is identical
    # to the existing EpisodeFile record. Temporarily staging or renaming forces Sonarr to
    # re-import and refresh MediaInfo (updating EAC3 -> AC3).
    local dir_name base_name new_base_name staged_path staged_base
    dir_name=$(dirname "$host_path")
    base_name=$(basename "$host_path")

    new_base_name=$(echo "$base_name" | sed -E 's/E-?AC-?3/AC3/Ig; s/DDP/DD/g; s/DD\+/DD/g')
    if [ "$new_base_name" != "$base_name" ]; then
        staged_path="${dir_name}/${new_base_name}"
        mv "$host_path" "$staged_path"
        UPDATED_HOST_PATH="$staged_path"
        staged_base="$new_base_name"
    else
        staged_path="${host_path}.sonarr_rescan_tmp"
        mv "$host_path" "$staged_path"
        local drop_cmd
        drop_cmd=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" -H "Content-Type: application/json" \
            -X POST "${SONARR_URL}/api/v3/command" \
            -d "{\"name\":\"RescanSeries\",\"seriesId\":${series_id}}" | jq -r '.id // empty' 2> /dev/null)
        wait_arr_command "$SONARR_URL" "$SONARR_API_KEY" "$drop_cmd"
        mv "$staged_path" "$host_path"
        UPDATED_HOST_PATH="$host_path"
        staged_base="$base_name"
    fi

    echo "    [*] Sonarr: Triggering RescanSeries (ID: $series_id)..."
    local cmd_id
    cmd_id=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" -H "Content-Type: application/json" \
        -X POST "${SONARR_URL}/api/v3/command" \
        -d "{\"name\":\"RescanSeries\",\"seriesId\":${series_id}}" | jq -r '.id // empty' 2> /dev/null)
    wait_arr_command "$SONARR_URL" "$SONARR_API_KEY" "$cmd_id"

    # Check if Sonarr wants to rename the modified episode file
    local rename_json rename_ids new_rel_path
    rename_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" "${SONARR_URL}/api/v3/rename?seriesId=${series_id}" 2> /dev/null)
    rename_ids=$(echo "$rename_json" | jq -c --arg f "$staged_base" '[.[] | select(.existingPath | endswith($f)) | .episodeFileId] // []' 2> /dev/null)
    new_rel_path=$(echo "$rename_json" | jq -r --arg f "$staged_base" '[.[] | select(.existingPath | endswith($f)) | .newPath][0] // empty' 2> /dev/null)

    if [ -n "$rename_ids" ] && [ "$rename_ids" != "[]" ] && [ "$rename_ids" != "null" ]; then
        echo "    [*] Sonarr: Renaming episode file to match new MediaInfo..."
        local rename_cmd
        rename_cmd=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" -H "Content-Type: application/json" \
            -X POST "${SONARR_URL}/api/v3/command" \
            -d "{\"name\":\"RenameFiles\",\"seriesId\":${series_id},\"files\":${rename_ids}}" | jq -r '.id // empty' 2> /dev/null)
        wait_arr_command "$SONARR_URL" "$SONARR_API_KEY" "$rename_cmd"
        if [ -n "$new_rel_path" ]; then
            local candidate
            candidate="${dir_name}/$(basename "$new_rel_path")"
            if [ -f "$candidate" ]; then
                UPDATED_HOST_PATH="$candidate"
            fi
        fi
    fi

    echo "    [✔] Sonarr: Episode updated ($(basename "$UPDATED_HOST_PATH"))."
    return 0
}

# Route media update to Radarr or Sonarr based on path / patterns
update_arr_media() {
    local host_path="$1"
    UPDATED_HOST_PATH="$host_path"

    local handled=false
    if [[ "$host_path" =~ \{tvdb-[0-9]+\} ]] || [[ "$host_path" =~ /tv/ ]] || [[ "$host_path" =~ /tv- ]]; then
        if update_sonarr_episode "$host_path" || update_radarr_movie "$host_path"; then
            handled=true
        fi
    else
        if update_radarr_movie "$host_path" || update_sonarr_episode "$host_path"; then
            handled=true
        fi
    fi

    # Fallback: if not managed by Radarr/Sonarr, still update EAC3/DDP tokens in the filename on disk
    if [ "$handled" = false ]; then
        local dir_name base_name new_base_name
        dir_name=$(dirname "$host_path")
        base_name=$(basename "$host_path")
        new_base_name=$(echo "$base_name" | sed -E 's/E-?AC-?3/AC3/Ig; s/DDP/DD/g; s/DD\+/DD/g')
        if [ "$new_base_name" != "$base_name" ]; then
            mv "$host_path" "${dir_name}/${new_base_name}"
            UPDATED_HOST_PATH="${dir_name}/${new_base_name}"
        fi
        echo "    [i] Arr: File not matched in Radarr or Sonarr; updated filename locally ($(basename "$UPDATED_HOST_PATH"))."
    fi
}

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
    HOST_PATH=$(translate_plex_to_host "$PLEX_PATH")

    if [ ! -f "$HOST_PATH" ]; then
        echo "[x] Skipped: File not found on host (Check path translation!): $HOST_PATH"
        continue
    fi

    echo "[*] Processing: $(basename "$HOST_PATH")"

    if [ "$DRY_RUN" = false ]; then
        HOST_DIR=$(dirname "$HOST_PATH")
        EXT="${HOST_PATH##*.}"
        TMP_FILE="${HOST_PATH%.*}.tmp.${EXT}"

        # Run FFmpeg (Copy Video, Copy Subtitles, Convert Audio to AC3 5.1 640k)
        # Using -nostdin to prevent ffmpeg from swallowing loop input
        if run_ffmpeg "$HOST_DIR" -nostdin -y -v error -i "$HOST_PATH" -map 0 -c:v copy -c:s copy -c:a ac3 -b:a 640k "$TMP_FILE" < /dev/null && [ -s "$TMP_FILE" ]; then
            # Swap the fixed file into place
            mv "$TMP_FILE" "$HOST_PATH"
            chmod 0666 "$HOST_PATH"
            chown nobody:users "$HOST_PATH" 2> /dev/null || true

            # Update Radarr or Sonarr (rescan & rename if applicable)
            update_arr_media "$HOST_PATH"
            FINAL_PLEX_PATH=$(translate_host_to_plex "$UPDATED_HOST_PATH")

            echo "    [*] Instructing Plex to re-analyze..."
            if [ "$FINAL_PLEX_PATH" != "$PLEX_PATH" ]; then
                PLEX_DIR=$(dirname "$FINAL_PLEX_PATH")
                docker exec "$PLEX_CONT" env PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="$PLEX_APP_SUPPORT" "${PLEX_BIN_DIR}/Plex Media Scanner" --scan --refresh --directory "$PLEX_DIR" > /dev/null 2>&1 < /dev/null
            fi
            docker exec "$PLEX_CONT" env PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR="$PLEX_APP_SUPPORT" "${PLEX_BIN_DIR}/Plex Media Scanner" --analyze --file "$FINAL_PLEX_PATH" > /dev/null 2>&1 < /dev/null

            # Track to fixed list
            echo "$UPDATED_HOST_PATH" >> "$FIXED_FILE"
            echo "[✔] Fixed and re-analyzed: $(basename "$UPDATED_HOST_PATH")"

            # Safely remove the file from the original list so it can resume cleanly if interrupted
            sed -i '' "\|${PLEX_PATH}|d" "$LIST_FILE" 2> /dev/null || sed -i "\|${PLEX_PATH}|d" "$LIST_FILE"
        else
            echo "[x] FFmpeg failed on $HOST_PATH. Deleting corrupt temp file."
            rm -f "$TMP_FILE"
        fi
    else
        echo "    [DRY RUN] Would convert audio to AC3 640k, notify Radarr/Sonarr, and re-analyze in Plex."
    fi

    echo "--------------------------------------------------------"
done < "${LIST_FILE}.run"

# Cleanup the iteration file
rm -f "${LIST_FILE}.run"

echo "All Done!"
