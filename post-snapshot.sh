#!/bin/bash

# Post-Snapshot Hook: Restart containers in Docker tab order and respect startup delays

set -euo pipefail

STATE_FILE="/boot/config/plugins/buddybackup/hooks/running_containers.state"

if [ ! -f "$STATE_FILE" ]; then
    echo "No state file found. Containers were either not stopped or the file was deleted."
    exit 0
fi

echo "Restarting Docker containers..."
while IFS=' ' read -r container wait_time || [ -n "$container" ]; do
    [ -z "$container" ] && continue
    echo "Starting: $container"
    docker start "$container" > /dev/null

    if [ -n "$wait_time" ] && [ "$wait_time" -gt 0 ] 2> /dev/null; then
        echo "Waiting ${wait_time}s after starting $container..."
        sleep "$wait_time"
    fi
done < "$STATE_FILE"

# Clean up the state file after a successful run
rm -f "$STATE_FILE"
echo "All containers restarted successfully."
