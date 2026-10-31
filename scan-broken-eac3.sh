#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: PLEX EAC3 CORRUPTION SCANNER & AUTO-FIXER
# ==============================================================================
# PURPOSE:
#   Scans your entire Plex library for severely corrupted EAC3 (Dolby Digital Plus)
#   audio tracks that cause the Plex EasyAudioEncoder (EAE) to hard-crash, and
#   optionally converts them in-place to AC3 640k while updating Plex, Radarr,
#   and Sonarr.
#
# HOW IT WORKS:
#   1. Queries the Plex SQLite database to find all EAC3 files (<= 6 channels).
#   2. Spawns an isolated instance of Plex's proprietary EAE transcoder engine.
#   3. Feeds 50 frames of each file directly into the engine.
#   4. If the engine spits out continuous "Cannot group in blocks of 6!" errors,
#      the file is flagged as corrupted.
#   5. If FIX_AUDIO is true, converts the audio track in-place to AC3 640k
#      (using host ffmpeg or the linuxserver/ffmpeg Docker image), instructs
#      Radarr or Sonarr to rescan/rename the media file, and tells Plex to
#      re-analyze the file. Otherwise, logs the file to broken-eac3-list.txt.
#
# USAGE:
#   Configure the variables below (or override them from the environment):
#   Run normally:       ./scan-broken-eac3.sh
#   Preview fixes:      FIX_AUDIO=true ./scan-broken-eac3.sh               (DRY_RUN defaults to true)
#   Apply fixes:        FIX_AUDIO=true DRY_RUN=false ./scan-broken-eac3.sh
#   Resume scan:        CONTINUE_FROM=4400 ./scan-broken-eac3.sh
#   Scan last 24 hours: RECENT_HOURS=24 ./scan-broken-eac3.sh
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN="${DRY_RUN:-true}"                         # Set to 'false' to actively convert files and update Plex/Radarr/Sonarr
FIX_AUDIO="${FIX_AUDIO:-false}"                    # Set to 'true' to convert corrupted EAC3 audio to AC3 in-place
FFMPEG_IMAGE="${FFMPEG_IMAGE:-linuxserver/ffmpeg}" # Docker image used when ffmpeg is not installed on the host
CONTINUE_FROM="${CONTINUE_FROM:-0}"                # Resume scanning from this file index (0 starts from the beginning)
RECENT_HOURS="${RECENT_HOURS:-0}"                  # Only scan files added in the last X hours (0 scans everything)

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
# ==========================================

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

PLEX_CONT=$(docker ps --format '{{.Names}}' | grep -i '^plex$' | head -n 1)
if [ -z "$PLEX_CONT" ]; then
    PLEX_CONT=$(docker ps --format '{{.Names}}' | grep -i plex | head -n 1)
fi
if [ -z "$PLEX_CONT" ]; then
    echo "Error: Could not find a Plex docker container running."
    exit 1
fi
echo "Using Plex container: $PLEX_CONT"
echo "Auto-Fix Audio Mode: $FIX_AUDIO"
if [ "$FIX_AUDIO" = true ]; then
    echo "Dry Run Mode: $DRY_RUN"
fi

# Locate Plex binaries inside the container (supports Hotio, Official, LinuxServer, Binhex)
if docker exec "$PLEX_CONT" test -f "/app/bin/usr/lib/plexmediaserver/Plex Transcoder"; then
    PLEX_BIN_DIR="/app/bin/usr/lib/plexmediaserver"
else
    PLEX_BIN_DIR="/usr/lib/plexmediaserver"
fi

# Auto-populate PATH_MAPPINGS from docker inspect mounts as fallback
while IFS='|' read -r dst src; do
    if [ -n "$dst" ] && [ -n "$src" ] && [ -z "${PATH_MAPPINGS[$dst]+_}" ]; then
        PATH_MAPPINGS["$dst"]="$src"
    fi
done < <(docker inspect "$PLEX_CONT" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2> /dev/null)

# Prepare FFmpeg, Radarr, and Sonarr if FIX_AUDIO is enabled
HAS_HOST_FFMPEG=false
if [ "$FIX_AUDIO" = true ]; then
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

# Route media update to Radarr or Sonarr based on Plex metadata_type (1=movie, 4=episode) and path
update_arr_media() {
    local host_path="$1"
    local metadata_type="$2"
    UPDATED_HOST_PATH="$host_path"

    local handled=false
    if [ "$metadata_type" = "4" ] || [[ "$host_path" =~ \{tvdb-[0-9]+\} ]]; then
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

echo "Locating Plex database..."
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

# Get all EAC3 files with 6 or fewer channels (Standard 5.1 and Stereo), along with library_section_id and metadata_type
sqlite3 -separator '|' /tmp/plex_db_copy.db "
SELECT media_items.library_section_id, metadata_items.metadata_type, media_parts.file
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
FIXED_FILE="$(pwd)/fixed-eac3-list.txt"

# If we are starting from 0, clear the output file. Otherwise, append to it.
if [ "$CONTINUE_FROM" -eq 0 ]; then
    : > "$OUTPUT_FILE"
    : > "$FIXED_FILE"
    echo "Starting deep scan from the beginning..."
else
    echo "Resuming scan from file #$CONTINUE_FROM. Appending to existing broken-eac3-list.txt..."
fi

COUNT=0
FIXED=0
WOULD_FIX=0
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

while IFS='|' read -r section_id metadata_type file; do
    [ -z "$file" ] && continue
    COUNT=$((COUNT + 1))

    # Fast-forward until we hit our starting point
    if [ "$COUNT" -lt "$CONTINUE_FROM" ]; then
        # Just update the display quickly so the user knows it's skipping
        if [ $((COUNT % 500)) -eq 0 ]; then
            format_num "$COUNT" COUNT_FMT
            echo -ne "Skipping to $CONTINUE_FROM... currently at $COUNT_FMT \r"
        fi
        continue
    fi

    # Securely wipe and recreate the EAE watchfolder so the engine has a pristine environment
    docker exec "$PLEX_CONT" sh -c 'rm -rf "/tmp/eae_test"; mkdir -p "/tmp/eae_test/Convert to WAV (to 8ch or less)"; chmod -R 777 /tmp/eae_test'

    # Format counts for display
    format_num "$COUNT" COUNT_FMT
    format_num "$BROKEN" BROKEN_FMT
    format_num "$FIXED" FIXED_FMT

    # Print status (overwrites the line)
    if [ "$FIX_AUDIO" = true ]; then
        echo -ne "Scanning $COUNT_FMT / $TOTAL_FMT  |  Corrupted: $BROKEN_FMT  |  Fixed: $FIXED_FMT \r"
    else
        echo -ne "Scanning $COUNT_FMT / $TOTAL_FMT  |  Corrupted: $BROKEN_FMT \r"
    fi

    ERR=$(docker exec "$PLEX_CONT" timeout 10 env EAE_ROOT=/tmp/eae_test "${PLEX_BIN_DIR}/Plex Transcoder" -y -nostdin -v error -i "$file" -map 0:a:0 -frames:a 50 -f wav /dev/null 2>&1 < /dev/null)

    # Ignore "No such file" errors
    if echo "$ERR" | grep -q "No such file or directory"; then
        continue
    fi

    # Count how many bad blocks it hit
    ERROR_COUNT=$(echo "$ERR" | grep -c "Cannot group in blocks of 6!")

    # If it spewed continuous corruption errors (> 10)
    if [ "$ERROR_COUNT" -gt 10 ]; then
        echo -e "\n[CORRUPT] $file"
        BROKEN=$((BROKEN + 1))

        if [ "$FIX_AUDIO" = true ]; then
            HOST_PATH=$(translate_plex_to_host "$file")
            if [ ! -f "$HOST_PATH" ]; then
                echo "    [✖] Fix failed: Host file not found ($HOST_PATH). Check PATH_MAPPINGS."
                echo "$file" >> "$OUTPUT_FILE"
                continue
            fi

            if [ "$DRY_RUN" = true ]; then
                echo "    [DRY RUN] Would convert audio to AC3 640k in-place, then update Radarr/Sonarr and re-analyze in Plex: $(basename "$HOST_PATH")"
                WOULD_FIX=$((WOULD_FIX + 1))
                echo "$file" >> "$OUTPUT_FILE"
                continue
            fi

            HOST_DIR=$(dirname "$HOST_PATH")
            EXT="${HOST_PATH##*.}"
            TMP_FILE="${HOST_PATH%.*}.tmp.${EXT}"

            echo "    [*] Converting audio to AC3 640k in-place: $(basename "$HOST_PATH")"
            if run_ffmpeg "$HOST_DIR" -nostdin -y -v error -i "$HOST_PATH" -map 0 -c:v copy -c:s copy -c:a ac3 -b:a 640k "$TMP_FILE" < /dev/null && [ -s "$TMP_FILE" ]; then
                mv "$TMP_FILE" "$HOST_PATH"
                chmod 0666 "$HOST_PATH"
                chown nobody:users "$HOST_PATH" 2> /dev/null || true

                # Update Radarr or Sonarr (rescan & rename if applicable)
                update_arr_media "$HOST_PATH" "$metadata_type"
                FINAL_PLEX_PATH=$(translate_host_to_plex "$UPDATED_HOST_PATH")

                echo "    [*] Instructing Plex to re-analyze..."
                if [ "$FINAL_PLEX_PATH" != "$file" ] && [ -n "$section_id" ]; then
                    PLEX_DIR=$(dirname "$FINAL_PLEX_PATH")
                    docker exec "$PLEX_CONT" "${PLEX_BIN_DIR}/Plex Media Scanner" --scan --refresh --section "$section_id" --directory "$PLEX_DIR" > /dev/null 2>&1 < /dev/null
                fi
                docker exec "$PLEX_CONT" "${PLEX_BIN_DIR}/Plex Media Scanner" --analyze --file "$FINAL_PLEX_PATH" > /dev/null 2>&1 < /dev/null

                FIXED=$((FIXED + 1))
                echo "$UPDATED_HOST_PATH" >> "$FIXED_FILE"
                echo "    [✔] Fixed and re-analyzed: $(basename "$UPDATED_HOST_PATH")"
            else
                echo "    [✖] FFmpeg conversion failed on $HOST_PATH. Cleaning up temp file."
                rm -f "$TMP_FILE"
                echo "$file" >> "$OUTPUT_FILE"
            fi
        else
            echo "$file" >> "$OUTPUT_FILE"
        fi
    fi

done < /tmp/eac3-51-files.txt

format_num "$BROKEN" BROKEN_FMT
format_num "$FIXED" FIXED_FMT
format_num "$WOULD_FIX" WOULD_FIX_FMT

echo -e "\n-----------------------------------------------------------------"
if [ "$FIX_AUDIO" = true ] && [ "$DRY_RUN" = true ]; then
    echo "Dry run complete! Found $BROKEN_FMT corrupted files; $WOULD_FIX_FMT would be fixed. No files were modified."
    echo "Re-run with DRY_RUN=false (or --no-dry-run) to apply fixes."
    echo "List saved to $OUTPUT_FILE"
elif [ "$FIX_AUDIO" = true ]; then
    echo "Scan complete! Found $BROKEN_FMT corrupted files; fixed $FIXED_FMT in-place."
    if [ "$FIXED" -gt 0 ]; then
        echo "Fixed files saved to $FIXED_FILE"
    fi
    if [ "$BROKEN" -gt "$FIXED" ]; then
        echo "Unfixed files saved to $OUTPUT_FILE"
    fi
else
    echo "Scan complete! Found a total of $BROKEN_FMT severely broken files."
    echo "List saved to $OUTPUT_FILE"
fi

# Trigger Unraid WebGUI Notification ONLY if running in the background (e.g. User Scripts plugin)
# The [ ! -t 1 ] check ensures notifications are skipped if a user runs it manually in the shell/terminal.
if [ "$BROKEN" -gt 0 ] && [ -f "/usr/local/emhttp/webGui/scripts/notify" ] && [ ! -t 1 ] && ! grep -q "startScript.sh" "/proc/${PPID}/cmdline" 2> /dev/null; then
    if [ "$FIX_AUDIO" = true ] && [ "$DRY_RUN" = true ]; then
        /usr/local/emhttp/webGui/scripts/notify -i warning -s "Plex EAC3 Scan (Dry Run)" -d "Found $BROKEN_FMT broken EAC3 files; $WOULD_FIX_FMT would be fixed. No files were modified."
    elif [ "$FIX_AUDIO" = true ]; then
        if [ "$FIXED" -le 3 ] && [ "$FIXED" -gt 0 ]; then
            FIXED_NAMES=$(while IFS= read -r f; do basename "$f"; done < "$FIXED_FILE" | paste -sd ", " -)
            /usr/local/emhttp/webGui/scripts/notify -i normal -s "Plex EAC3 Scan" -d "Fixed $FIXED_FMT file(s): $FIXED_NAMES"
        else
            /usr/local/emhttp/webGui/scripts/notify -i normal -s "Plex EAC3 Scan" -d "Found $BROKEN_FMT broken EAC3 files and fixed $FIXED_FMT in-place. See fixed-eac3-list.txt for details."
        fi
    else
        /usr/local/emhttp/webGui/scripts/notify -i warning -s "Plex EAC3 Scan" -d "Found $BROKEN_FMT broken EAC3 files. See broken-eac3-list.txt for details."
    fi
fi
