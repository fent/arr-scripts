#!/bin/bash

# Pre-Snapshot Hook: Gracefully stop stateful containers in reverse Docker tab order
# to ensure database and appdata consistency before snapshotting.

set -euo pipefail

STATE_FILE="/boot/config/plugins/buddybackup/hooks/running_containers.state"
USERPREFS="/boot/config/plugins/dockerMan/userprefs.cfg"
AUTOSTART="/var/lib/docker/unraid-autostart"
STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-60}"

rm -f "$STATE_FILE"

# 1. Determine defined container order from userprefs.cfg (keys 0, 1, 2...)
ordered_containers=()
if [ -f "$USERPREFS" ]; then
    while IFS='=' read -r _ val; do
        c_name=$(echo "$val" | tr -d '"\r')
        [ -n "$c_name" ] && ordered_containers+=("$c_name")
    done < <(sort -n -t'=' -k1,1 "$USERPREFS" 2> /dev/null || true)
fi

# Append any currently running container not in userprefs
for c in $(docker ps --format '{{.Names}}'); do
    found=0
    for oc in "${ordered_containers[@]}"; do
        if [ "$oc" = "$c" ]; then
            found=1
            break
        fi
    done
    [ $found -eq 0 ] && ordered_containers+=("$c")
done

# 2. Filter for running containers that mount appdata
to_stop=()
for c in "${ordered_containers[@]}"; do
    if docker ps -q -f name="^${c}$" | grep -q .; then
        if docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' 2> /dev/null | grep -i -q 'appdata'; then
            wait_time=0
            if [ -f "$AUTOSTART" ]; then
                w=$(awk -v name="$c" '$1 == name { print ($2 ? $2 : 0) }' "$AUTOSTART" 2> /dev/null || true)
                [ -n "$w" ] && wait_time="$w"
            fi
            to_stop+=("$c:$wait_time")
        fi
    fi
done

if [ ${#to_stop[@]} -eq 0 ]; then
    echo "No running stateful (appdata) containers detected."
    exit 0
fi

# 3. Save forward start order (top-to-bottom) with wait times to STATE_FILE
for item in "${to_stop[@]}"; do
    c="${item%%:*}"
    w="${item##*:}"
    echo "$c $w" >> "$STATE_FILE"
done

# 4. Stop in reverse order (bottom-to-top) with timeout
echo "Stopping Docker containers..."
for ((idx = ${#to_stop[@]} - 1; idx >= 0; idx--)); do
    item="${to_stop[idx]}"
    c="${item%%:*}"
    echo "Stopping $c (timeout: ${STOP_TIMEOUT}s)..."
    docker stop --time "$STOP_TIMEOUT" "$c" > /dev/null
done

echo "All stateful containers stopped."
