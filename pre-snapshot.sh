#!/bin/bash

# Pre-Snapshot Hook: Gracefully stop stateful containers in reverse Docker tab order
# to ensure database and appdata consistency before snapshotting.

# How long to wait before forcing a container to stop.
STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-}"

# Will only stop containers with a mount pointing to this.
TARGET_MOUNT_KEYWORD="${TARGET_MOUNT_KEYWORD:-appdata}"

# Any containers you want to ignore, space separated.
IGNORE_CONTAINERS="${IGNORE_CONTAINERS:-}"

# The container start order. This script will stop containers in reverse order,
# the post-snapshot script will resume containers in defined order.
CONTAINER_ORDER="${CONTAINER_ORDER:-}"

# Startup delay in seconds after starting each container.
START_DELAY="${START_DELAY:-}"

# Without any configuration set, the script tries to guess where config may
# reside, falling back to common system paths.
STATE_FILE="${STATE_FILE:-/tmp/backup_running_containers.state}"
USERPREFS="${USERPREFS:-/boot/config/plugins/dockerMan/userprefs.cfg}"
AUTOSTART="${AUTOSTART:-/var/lib/docker/unraid-autostart}"

set -euo pipefail

[ -n "$STATE_FILE" ] && rm -f "$STATE_FILE"

# Determine defined container start order
ordered_containers=()
if [ -n "$CONTAINER_ORDER" ]; then
    IFS=', ' read -r -a custom_order <<< "$CONTAINER_ORDER"
    for container in "${custom_order[@]}"; do
        [ -n "$container" ] && ordered_containers+=("$container")
    done
elif [ -f "$USERPREFS" ]; then
    while IFS='=' read -r _ val; do
        container=$(echo "$val" | tr -d '"\r')
        [ -n "$container" ] && ordered_containers+=("$container")
    done < <(sort -n -t'=' -k1,1 "$USERPREFS" 2> /dev/null || true)
fi

# Append any currently running container not in defined order
if [ -z "$CONTAINER_ORDER" ]; then
    for container in $(docker ps --format '{{.Names}}'); do
        found=0
        for ordered in "${ordered_containers[@]}"; do
            if [ "$ordered" = "$container" ]; then
                found=1
                break
            fi
        done
        [ $found -eq 0 ] && ordered_containers+=("$container")
    done
fi

# Filter for running containers that mount target data
to_stop=()
for container in "${ordered_containers[@]}"; do
    if docker ps -q -f name="^${container}$" | grep -q .; then
        # Check ignore list
        if [ -n "$IGNORE_CONTAINERS" ]; then
            is_ignored=0
            IFS=', ' read -r -a ignore_list <<< "$IGNORE_CONTAINERS"
            for ignored_container in "${ignore_list[@]}"; do
                if [ "$ignored_container" = "$container" ]; then
                    is_ignored=1
                    break
                fi
            done
            [ $is_ignored -eq 1 ] && continue
        fi

        # Check backup.ignore label
        if [ "$(docker inspect "$container" --format '{{index .Config.Labels "backup.ignore"}}' 2> /dev/null || true)" = "true" ]; then
            continue
        fi

        # Check mount keyword for start delay if set
        if [ -z "$TARGET_MOUNT_KEYWORD" ] || docker inspect "$container" --format '{{range .Mounts}}{{.Source}}{{println}}{{end}}' 2> /dev/null | grep -i -q "$TARGET_MOUNT_KEYWORD"; then
            start_delay=0
            if [ -n "$START_DELAY" ]; then
                start_delay="$START_DELAY"
            elif [ -f "$AUTOSTART" ]; then
                w=$(awk -v name="$container" '$1 == name { print ($2 ? $2 : 0) }' "$AUTOSTART" 2> /dev/null || true)
                [ -n "$w" ] && start_delay="$w"
            fi
            to_stop+=("$container:$start_delay")
        fi
    fi
done

if [ ${#to_stop[@]} -eq 0 ]; then
    echo "No running stateful (${TARGET_MOUNT_KEYWORD:-custom}) containers detected."
    exit 0
fi

# 3. Save forward start order (top-to-bottom) with wait times to STATE_FILE
if [ -n "$STATE_FILE" ]; then
    for entry in "${to_stop[@]}"; do
        container="${entry%%:*}"
        wait_time="${entry##*:}"
        echo "$container $wait_time" >> "$STATE_FILE"
    done
fi

# 4. Stop in reverse order (bottom-to-top) with timeout
echo "Stopping Docker containers..."
for ((idx = ${#to_stop[@]} - 1; idx >= 0; idx--)); do
    entry="${to_stop[idx]}"
    container="${entry%%:*}"
    echo "Stopping $container (timeout ${STOP_TIMEOUT}s)..."
    docker stop --time "$STOP_TIMEOUT" "$container" > /dev/null
done

echo "All stateful containers stopped."
