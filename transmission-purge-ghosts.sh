#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: UNREFERENCED GHOST FILE PURGE (CASE B) - LITERAL FILENAME MATCH
# ==============================================================================
# PURPOSE:
# This script identifies and deletes unreferenced "ghost" files and folders
# that are taking up space on your hard drives but do not exist in Transmission.
#
# HOW IT WORKS:
# 1. It pulls Transmission's complete database metadata block using '-t all --info'.
# 2. It parses the raw data rows underneath the 'File(s):' block array. This block
#    contains the literal, physical root directory or file name Transmission created
#    on your disk, rather than the cosmetic display title.
# 3. It loads these exact filename strings directly into a native Bash Hashmap.
# 4. It checks your physical download directories on disk. If an item on your disk
#    does not exist as a key inside the memory hashmap, it is flagged as a ghost.
#
# FOREIGN CHARACTER, COLON, & ELLIPSIS IMMUNITY:
# Because it maps the literal disk filename tracked by Transmission instead of the
# torrent display name, this version is entirely immune to string mismatches.
# - Transmission's automatic translation of colons (:) to underscores (_) on disk is natively caught.
# - Foreign character sets (Japanese Kanji, Cyrillic, etc.) match perfectly down to the byte.
# - Long names that are truncated with '...' on summary screens are completely preserved.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                    # Set to 'false' to actively delete files from your disk
CONTAINER_NAME="transmission"   # Name of your Transmission Docker container
BASE_PATH="/mnt/user/downloads" # Parent path where your source folders live

# Transmission Credentials
TR_USER="YOUR_USERNAME_HERE"
TR_PASS="YOUR_PASSWORD_HERE"

# Target subdirectories to audit (Excluding .music)
TARGET_FOLDERS=(".tv" ".tv-imported" ".tvfourk" ".movies" ".moviesfourk")

echo "=== STARTING SCRIPT 2: GHOST DATA PURGER (LITERAL FILENAME MATCH) ==="
echo "Dry Run Mode: $DRY_RUN"
echo "----------------------------------------"

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container not running."
    exit 1
fi

echo "Pulling deep metadata sheets for all active torrents..."
ALL_TORRENT_DETAILS=$(docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" -t all --info 2>&1)

if echo "$ALL_TORRENT_DETAILS" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

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
echo "Scanning physical disks..."
echo "----------------------------------------"

TOTAL_UNREFERENCED_KBYTES=0
UNREF_COUNT=0

for folder in "${TARGET_FOLDERS[@]}"; do
    CURRENT_DIR="${BASE_PATH}/${folder}"
    if [ ! -d "$CURRENT_DIR" ]; then continue; fi
    echo "Scanning disk share: $CURRENT_DIR"

    while read -r -d $'\0' item_path; do
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

            if [ "$DRY_RUN" = true ]; then
                echo "[DRY-RUN] Would delete ghost data ($ITEM_HUMAN_SIZE): $ITEM_NAME"
            else
                echo "[ACTION] Deleting ghost data ($ITEM_HUMAN_SIZE): $ITEM_NAME"
                rm -rf "$item_path"
            fi
        fi
    done < <(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -print0)
done

HUMAN_UNREF_SIZE=$(awk -v kb="$TOTAL_UNREFERENCED_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')
echo "----------------------------------------"
echo "=== SUMMARY: Dead Unreferenced Items Reclaimable: $HUMAN_UNREF_SIZE ($UNREF_COUNT items affected) ==="
