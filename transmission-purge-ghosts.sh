#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: TRANSMISSION PURGE GHOSTS
# ==============================================================================
# PURPOSE:
#   This script identifies and deletes unreferenced "ghost" files and folders
#   that are taking up space on your drives but do not exist in Transmission
#   nor are hardlinked to your media folders.
#
# HOW IT WORKS:
#   1. Builds a hashmap of all torrent filenames in Transmission.
#   2. It checks your download folders on disk. If an item on your disk
#      does not exist as in the hashmap, it is flagged as a ghost.
#   3. If DRY_RUN is false, it deletes the match.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                             # Set to 'false' to actively delete files from your disk
INTERACTIVE=true                         # If true and running in a terminal, prompts for confirmation before deleting each item
CONTAINER_NAME="transmission"            # Name of the Transmission Docker container
DOWNLOADS_DIR="/mnt/user/data/downloads" # Parent path where your source folders live

# Transmission Credentials
TR_USER="YOUR_USERNAME_HERE"
TR_PASS="YOUR_PASSWORD_HERE"

# Target subdirectories to audit
TARGET_FOLDERS=("tv" "tv-fourk" "movies" "movies-fourk")

# Table Formatting
COL_NAME=105
COL_SIZE=10
COL_TOTAL=$((COL_NAME + COL_SIZE + 3))
NBSP=$'\xC2\xA0' # Non-breaking space for web UI formatting

echo "=== STARTING TRANSMISSION PURGE GHOSTS ==="
echo "Dry Run Mode: $DRY_RUN"
echo "----------------------------------------"

# Save original stdin (fd 3) so interactive prompts can read from terminal even inside redirected loops
exec 3<&0
trap 'exec 3<&-' EXIT
ABORT_PURGE=false
PURGED_COUNT=0
PURGED_KBYTES=0

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

echo "Fetching torrent manifest from Transmission..."
if ! RAW_MANIFEST=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1); then
    echo "ERROR: Failed to connect to Transmission RPC."
    echo "Output: $RAW_MANIFEST"
    exit 1
fi

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

# A valid response will ALWAYS contain a "Sum:" row, even if there are 0 torrents loaded.
if ! echo "$RAW_MANIFEST" | grep -q "Sum:"; then
    echo "ERROR: Transmission did not return a valid torrent list. Safety abort."
    echo "Output: $RAW_MANIFEST"
    exit 1
fi

echo "Pulling deep metadata sheets for all active torrents..."
ALL_TORRENT_DETAILS=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t all --info 2>&1)

# -----------------------------------------------------------------
# POPULATE HASHMAP WITH LITERAL DISK PAYLOAD PATH NAMES
# -----------------------------------------------------------------
declare -A LIVE_FILENAME_MAP

while IFS= read -r info_line; do
    # Extract the "  Name: <value>" field from each torrent block.
    if [[ "$info_line" =~ ^[[:space:]]+Name:[[:space:]]+(.+)$ ]]; then
        disk_name="${BASH_REMATCH[1]}"
        if [ -n "$disk_name" ]; then
            # Apply Transmission's sanitize_subpath rules (libtransmission/torrent-files.cc).
            # On Linux, os_specific=false so it replaces Win32 reserved chars AND control chars:
            #   " * : < > ? \ |  ->  _
            # (Forward slash is handled as a path separator, not present in the root name.)
            disk_name=$(printf '%s' "$disk_name" | tr '"*:<>?\\|' '_________')
            LIVE_FILENAME_MAP["$disk_name"]=1
        fi
    fi
done <<< "$ALL_TORRENT_DETAILS"

echo "Database mapping complete (${#LIVE_FILENAME_MAP[@]} physical root assets cached)."
echo "Scanning disk shares: ${TARGET_FOLDERS[*]}..."
echo "----------------------------------------"

TOTAL_UNREFERENCED_KBYTES=0
UNREF_COUNT=0

for folder in "${TARGET_FOLDERS[@]}"; do
    CURRENT_DIR="${DOWNLOADS_DIR}/${folder}"
    if [ ! -d "$CURRENT_DIR" ]; then continue; fi

    echo "Scanning disk share: $CURRENT_DIR"
    HEADER_PRINTED=false

    # Pre-cache directory contents to prevent index shifting when items are deleted
    ITEM_PATHS=()
    while read -r -d $'\0' p; do
        ITEM_PATHS+=("$p")
    done < <(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -print0)

    for item_path in "${ITEM_PATHS[@]}"; do
        ITEM_NAME=$(basename "$item_path")
        TORRENT_MATCH=false

        # Matches your actual folder string on disk directly to what Transmission wrote on disk
        if [ "${LIVE_FILENAME_MAP["$ITEM_NAME"]}" ]; then
            TORRENT_MATCH=true
        fi

        if [ "$TORRENT_MATCH" = false ]; then
            ITEM_KBYTES=$(du -s "$item_path" | awk '{print $1}')
            TOTAL_UNREFERENCED_KBYTES=$((TOTAL_UNREFERENCED_KBYTES + ITEM_KBYTES))
            UNREF_COUNT=$((UNREF_COUNT + 1))
            ITEM_HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

            if [ "$HEADER_PRINTED" = false ]; then
                printf "%-*s | %-*s\n" "$COL_NAME" "Name" "$COL_SIZE" "Size" | sed "s/  /${NBSP}${NBSP}/g"
                printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
                HEADER_PRINTED=true
            fi

            disp_name="$ITEM_NAME"
            if [ ${#disp_name} -gt $COL_NAME ]; then
                trunc_len=$((COL_NAME - 3))
                disp_name="${disp_name:0:$trunc_len}..."
            fi

            # Compensate for Bash printf multibyte padding bug
            len_char=${#disp_name}
            len_byte=$(printf "%s" "$disp_name" | wc -c)
            name_width=$((COL_NAME + len_byte - len_char))

            printf "%-*s | %-*s\n" "$name_width" "$disp_name" "$COL_SIZE" "$ITEM_HUMAN_SIZE" | sed "s/  /${NBSP}${NBSP}/g"

            if [ "$DRY_RUN" = false ]; then
                should_delete=true
                if [ "$INTERACTIVE" = true ] && [ -t 3 ]; then
                    read -r -p "  ▸ Delete this ghost? [y/N/q]: " choice <&3
                    case "$choice" in
                    [yY] | [yY][eE][sS])
                        should_delete=true
                        ;;
                    [qQ] | [qQ][uU][iI][tT])
                        echo "  ▸ Aborting."
                        should_delete=false
                        ABORT_PURGE=true
                        break
                        ;;
                    *)
                        echo "  ▸ Skipped."
                        should_delete=false
                        ;;
                    esac
                fi

                if [ "$should_delete" = true ]; then
                    rm -rf "$item_path"
                    PURGED_COUNT=$((PURGED_COUNT + 1))
                    PURGED_KBYTES=$((PURGED_KBYTES + ITEM_KBYTES))
                fi
            fi
        fi
    done

    if [ "$HEADER_PRINTED" = true ]; then
        printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
    fi

    if [ "$ABORT_PURGE" = true ]; then
        break
    fi
done

HUMAN_UNREF_SIZE=$(awk -v kb="$TOTAL_UNREFERENCED_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
HUMAN_PURGED_SIZE=$(awk -v kb="$PURGED_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
echo "----------------------------------------"
if [ "$DRY_RUN" = true ]; then
    format_num "$UNREF_COUNT" UNREF_COUNT_FMT
    echo "=== SUMMARY: [DRY-RUN] $UNREF_COUNT_FMT ghost folders found, would reclaim $HUMAN_UNREF_SIZE ==="
else
    format_num "$PURGED_COUNT" PURGED_COUNT_FMT
    format_num "$UNREF_COUNT" UNREF_COUNT_FMT
    if [ "$PURGED_COUNT" -eq "$UNREF_COUNT" ]; then
        echo "=== SUMMARY: Purged $PURGED_COUNT_FMT ghost folders, reclaimed $HUMAN_PURGED_SIZE ==="
    else
        echo "=== SUMMARY: Purged $PURGED_COUNT_FMT of $UNREF_COUNT_FMT ghost folders, reclaimed $HUMAN_PURGED_SIZE ==="
    fi
fi

# Trigger Unraid WebGUI Notification ONLY if running in the background (e.g. User Scripts plugin)
# The [ ! -t 1 ] check ensures notifications are skipped if a user runs it manually in the shell/terminal.
if [ -f "/usr/local/emhttp/webGui/scripts/notify" ] && [ ! -t 1 ] && ! grep -q "startScript.sh" "/proc/${PPID}/cmdline" 2> /dev/null; then
    if [ "$DRY_RUN" = true ] && [ "$UNREF_COUNT" -gt 0 ]; then
        format_num "$UNREF_COUNT" UNREF_COUNT_FMT
        /usr/local/emhttp/webGui/scripts/notify -i normal -s "Transmission Ghosts (DRY RUN)" -d "Found $UNREF_COUNT_FMT ghost folders. Would reclaim $HUMAN_UNREF_SIZE."
    elif [ "$DRY_RUN" = false ] && [ "$PURGED_COUNT" -gt 0 ]; then
        format_num "$PURGED_COUNT" PURGED_COUNT_FMT
        /usr/local/emhttp/webGui/scripts/notify -i normal -s "Transmission Ghosts Purged" -d "Successfully purged $PURGED_COUNT_FMT ghost folders and reclaimed $HUMAN_PURGED_SIZE."
    fi
fi
