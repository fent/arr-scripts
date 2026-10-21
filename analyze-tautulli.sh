#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: TAUTULLI EAC3 TRANSCODE AUDITOR
# ==============================================================================
# PURPOSE:
#   Analyzes your Tautulli database to determine exactly which users and devices
#   are vulnerable to Plex's EAC3 transcoder crashes.
#
# HOW IT WORKS:
#   1. Locates your running Tautulli docker container.
#   2. Cross-references historical play sessions with media codec data.
#   3. Outputs a table showing how many times each user played an EAC3 file,
#      and whether their device forced a vulnerable audio transcode or Direct Played.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
CONTAINER_NAME="tautulli" # Name of the Tautulli Docker container

echo "=== STARTING ANALYZE TAUTULLI ==="
echo "----------------------------------------"

# Find the Tautulli container dynamically
TAUTULLI_CONT=$(docker ps --format '{{.Names}}' | grep -i "$CONTAINER_NAME" | head -n 1)

if [ -z "$TAUTULLI_CONT" ]; then
    echo "Error: Could not find a Tautulli docker container running."
    exit 1
fi

echo "Found Tautulli container: $TAUTULLI_CONT"
echo ""

QUERY="
SELECT h.user,
       h.product,
       COUNT(*) as total_eac3_plays,
       SUM(CASE WHEN m.audio_decision = 'transcode' THEN 1 ELSE 0 END) as transcoded,
       SUM(CASE WHEN m.audio_decision IN ('direct play', 'copy') THEN 1 ELSE 0 END) as direct_played
FROM session_history h
JOIN session_history_media_info m ON h.id = m.id
WHERE m.audio_codec LIKE '%eac3%'
GROUP BY h.user, h.product
ORDER BY transcoded DESC;
"

# Method 1: Try running sqlite3 directly inside the container
if docker exec "$TAUTULLI_CONT" command -v sqlite3 > /dev/null 2>&1; then
    docker exec -i "$TAUTULLI_CONT" sqlite3 /config/tautulli.db -header -column "$QUERY"

# Method 2: Fallback to reading the Docker mounts and running it on the Unraid host
else
    echo "Notice: sqlite3 not found inside container. Falling back to host extraction..."

    # Extract the host path mapped to /config
    HOST_PATH=$(docker inspect "$TAUTULLI_CONT" --format '{{ range .Mounts }}{{ if eq .Destination "/config" }}{{ .Source }}{{ end }}{{ end }}')

    if [ -n "$HOST_PATH" ] && [ -f "$HOST_PATH/tautulli.db" ]; then
        sqlite3 "$HOST_PATH/tautulli.db" -header -column "$QUERY"
    else
        echo "Error: Could not locate tautulli.db on the host system."
        exit 1
    fi
fi
