#!/bin/bash

# Post-Snapshot Hook: Restart containers in Docker tab order and respect startup delays

# Set to 'true' to simulate without starting containers.
DRY_RUN="${DRY_RUN:-false}"

# Reads stopped containers and delays recorded by pre-snapshot.sh.
STATE_FILE="${STATE_FILE:-/tmp/backup_running_containers.state}"

set -euo pipefail

if [ "$DRY_RUN" = true ]; then
    echo "Dry Run Mode: $DRY_RUN"
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "No state file found at $STATE_FILE. Containers were either not stopped or the file was deleted."
    exit 0
fi

echo "Restarting Docker containers..."
while IFS=' ' read -r container wait_time || [ -n "$container" ]; do
    [ -z "$container" ] && continue
    echo "Starting $container"
    if [ "$DRY_RUN" = false ]; then
        docker start "$container" > /dev/null

        if [ -n "$wait_time" ] && [ "$wait_time" -gt 0 ] 2> /dev/null; then
            echo "Waiting ${wait_time}s after starting $container..."
            sleep "$wait_time"
        fi
    fi
done < "$STATE_FILE"

# Clean up the state file after a successful run
if [ "$DRY_RUN" = false ]; then
    rm -f "$STATE_FILE"
fi
echo "All containers restarted successfully."
