#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: GHOST LINK RESCUER
# ==============================================================================
# PURPOSE:
#   Identifies download folder items that have disappeared from Transmission's
#   session (e.g. after a Transmission database reset or container recreate)
#   but whose files are still on disk AND still hard-linked to the media library.
#   These "ghost" items are safe to re-add to Transmission for continued seeding
#   because their data is intact and their library link is already in place.
#
# HOW IT WORKS:
#   1. Builds an exact-match hashmap of all torrent names currently known to
#      Transmission, applying the same filename sanitization rules Transmission
#      uses on disk (Win32 reserved chars → '_').
#   2. Walks each configured download folder and flags items NOT found in the
#      hashmap (i.e. missing from Transmission's session).
#   3. For each missing item, checks whether it still has a hard link to the
#      media library (link count > 1). Only linked items are flagged as rescue
#      candidates — unlinked items are left for the orphan or ghost purgers.
#   4. Reports all rescue candidates so they can be re-added to Transmission.
#
# SAFETY GATES:
#   - Only flags items with confirmed library hard links; lone disk copies are
#     ignored and handled by other scripts.
#   - DRY_RUN mode (default) reports candidates without taking any action.
#   - Actual re-injection requires the original .torrent file or magnet link
#     and is intentionally left as a manual step.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                    # Set to 'false' to actively resume/re-inject into Transmission
CONTAINER_NAME="transmission"   # Name of your Transmission Docker container
BASE_PATH="/mnt/user/downloads" # Parent path where your shares live

# Transmission Credentials
TR_USER="YOUR_USERNAME_HERE"          # <--- CHANGE THIS
TR_PASS="YOUR_PASSWORD_HERE" # <--- CHANGE THIS

# Source folders to inspect for ghost assets
SOURCE_FOLDERS=(".tv" ".tv-imported" ".tvfourk" ".movies" ".moviesfourk")

# Media Extensions Filter
MEDIA_EXTS="mkv|mp4|avi|mov|wmv|flv|webm|ts|m4v"

# Table Formatting
COL_NAME=105
COL_SIZE=10
COL_TOTAL=$((COL_NAME + COL_SIZE + 3))

echo "=== STARTING TRANSMISSION GHOST-LINK RESCUER ==="
echo "Dry Run Mode: $DRY_RUN"
echo "----------------------------------------"

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

echo "Caching active torrent list from Transmission..."
RAW_MANIFEST=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1)

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed."
    exit 1
fi

# Build a hashmap of sanitized torrent names for O(1) exact-match lookups.
# We use --info (not --list) so we get the full untruncated Name: field.
# We then apply Transmission's sanitize_subpath rules (libtransmission/torrent-files.cc):
# on Linux, os_specific=false so Win32 reserved chars (", *, :, <, >, ?, \, |) -> '_'.
# This makes the hashmap key match the literal folder/file name written to disk.
echo "Building sanitized torrent name index..."
ALL_TORRENT_DETAILS=$(docker exec "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t all --info 2>/dev/null)
declare -A LIVE_NAME_MAP
while IFS= read -r info_line; do
    if [[ "$info_line" =~ ^[[:space:]]+Name:[[:space:]]+(.+)$ ]]; then
        disk_name="${BASH_REMATCH[1]}"
        if [ -n "$disk_name" ]; then
            disk_name=$(printf '%s' "$disk_name" | tr '"*:<>?\\|' '_________')
            LIVE_NAME_MAP["$disk_name"]=1
        fi
    fi
done <<<"$ALL_TORRENT_DETAILS"
echo "Index built (${#LIVE_NAME_MAP[@]} torrents cached)."
echo "Scanning disk shares: ${SOURCE_FOLDERS[*]}..."
echo "----------------------------------------"

TOTAL_RESCUED_COUNT=0
TOTAL_RESCUED_SIZE_KBYTES=0

for folder in "${SOURCE_FOLDERS[@]}"; do
    CURRENT_SRC_DIR="${BASE_PATH}/${folder}"
    if [ ! -d "$CURRENT_SRC_DIR" ]; then continue; fi

    echo "Auditing folder for link-connected ghosts: $CURRENT_SRC_DIR"
    HEADER_PRINTED=false

    # Scan everything at depth 1 (files and folders)
    while read -r -d $'\0' item_path; do
        ITEM_NAME=$(basename "$item_path")

        # Exact hashmap lookup against sanitized torrent names — skip if already in Transmission
        if [ "${LIVE_NAME_MAP["$ITEM_NAME"]+_}" ]; then
            continue
        fi

        # We found a true Ghost Item (On disk, but missing from Transmission)
        # Now verify if it has a hard link in the media library (Link Count >= 2)
        is_linked_ghost=false
        item_size_kb=0

        if [ -d "$item_path" ]; then
            # If it's a folder, look inside for a media file that has links
            while read -r -d $'\0' media_file; do
                if basename "$media_file" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                    link_count=$(stat -c '%h' "$media_file")
                    if [ "$link_count" -gt 1 ]; then
                        is_linked_ghost=true
                        break
                    fi
                fi
            done < <(find "$item_path" -type f -print0 2>/dev/null)
        else
            # If it's a single file, check its link count directly
            if echo "$ITEM_NAME" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                link_count=$(stat -c '%h' "$item_path")
                if [ "$link_count" -gt 1 ]; then
                    is_linked_ghost=true
                fi
            fi
        fi

        # -----------------------------------------------------------------
        # RESCUE ENGINE: Process verified linked ghost items
        # -----------------------------------------------------------------
        if [ "$is_linked_ghost" = true ]; then
            item_size_kb=$(du -s "$item_path" | awk '{print $1}')
            TOTAL_RESCUED_SIZE_KBYTES=$((TOTAL_RESCUED_SIZE_KBYTES + item_size_kb))
            TOTAL_RESCUED_COUNT=$((TOTAL_RESCUED_COUNT + 1))
            HUMAN_SIZE=$(du -sh "$item_path" | awk '{print $1}')

            if [ "$HEADER_PRINTED" = false ]; then
                printf "%-*s | %-*s\n" "$COL_NAME" "Name" "$COL_SIZE" "Size"
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

            printf "%-*s | %-*s\n" "$name_width" "$disp_name" "$COL_SIZE" "$HUMAN_SIZE"

            if [ "$DRY_RUN" = false ]; then
                # NOTE: To perform automatic injection, the original .torrent file or magnet link
                # is needed. For now, this step alerts you with the exact path so it can be re-added safely.
                # If your torrent backup folder is known, we can automate the exact trigger line here.
                true
            fi
        fi

    done < <(find "$CURRENT_SRC_DIR" -maxdepth 1 -mindepth 1 -print0)

    if [ "$HEADER_PRINTED" = true ]; then
        printf '%*s\n' "$COL_TOTAL" "" | tr ' ' '-'
    fi
done

HUMAN_TOTAL_SIZE=$(awk -v kb="$TOTAL_RESCUED_SIZE_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')

echo "----------------------------------------"
echo "=== SUMMARY: Ghost Rescue Candidates Found: $TOTAL_RESCUED_COUNT ($HUMAN_TOTAL_SIZE) ==="
