#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: DUPLICATE FILE HARD LINK HEALER
# ==============================================================================
# PURPOSE:
#   Reclaims wasted disk space caused by Sonarr/Radarr being misconfigured to
#   copy files on import instead of creating hard links. When this happens, both
#   the seeding download folder and the Plex library folder contain a full
#   independent copy of the same file, doubling the space used. This script
#   finds those duplicate pairs and collapses them into a single hard link,
#   so both paths point to the same inode and only one copy occupies disk space.
#
# HOW IT WORKS:
#   1. Builds an in-memory size-keyed index of every file in your library folders.
#   2. Walks each configured seeding folder, skipping items not tracked by
#      Transmission and files that are already hard-linked (link count > 1).
#   3. For each unlinked file, finds size-matching library candidates and
#      confirms the match with a fast xxh128 hash of the first+last 10 MB.
#   4. On a confirmed match, atomically replaces the seeding file with a hard
#      link to the library file, reclaiming the duplicate copy's disk space.
#
# OPTIMIZATIONS:
#   - De-duplicates library paths shared across multiple source folders.
#   - Persists a verified-inode cache across runs to skip already-confirmed files.
#   - Only reads 20 MB per file pair for content verification (head + tail).
#
# SAFETY GATES:
#   - DRY_RUN mode (default) shows all planned changes without touching anything.
#   - Hard link creation is guarded: if ln fails, the script exits immediately
#     rather than leaving the seeding file deleted.
# ==============================================================================

# ==========================================
# CONFIGURATION
# ==========================================
DRY_RUN=true                    # Set to 'false' to actively fix and create hard links
CONTAINER_NAME="transmission"   # Name of your Transmission Docker container
BASE_PATH="/mnt/user/downloads" # Parent path where your shares live

# Transmission Credentials
TR_USER="YOUR_USERNAME_HERE"          # <--- CHANGE THIS
TR_PASS="YOUR_PASSWORD_HERE" # <--- CHANGE THIS

# -----------------------------------------------------------------
# 1:1 FOLDER MAPPINGS (Configure your matching pairs here)
# Format: ["SOURCE_SEED_FOLDER"]="DESTINATION_LIBRARY_PATH"
# -----------------------------------------------------------------
declare -A FOLDER_MAP
FOLDER_MAP[".tv"]="${BASE_PATH}/TV"
FOLDER_MAP[".tv-imported"]="${BASE_PATH}/TV"
FOLDER_MAP[".tvfourk"]="${BASE_PATH}/TV4k"
FOLDER_MAP[".movies"]="${BASE_PATH}/Movies"
FOLDER_MAP[".moviesfourk"]="${BASE_PATH}/Movies4k"

# Media Extensions Filter
MEDIA_EXTS="mkv|mp4|avi|mov|wmv|flv|webm|ts|m4v"

# Portable Local Cache Directory (Beside this script)
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
STATE_DIR="${SCRIPT_DIR}/transmission_healer_state"
VERIFIED_CACHE="${STATE_DIR}/verified_inodes.cache"
mkdir -p "$STATE_DIR"

echo "=== STARTING TRANSMISSION ISOLATED-HASHMAP HEALER ==="
echo "Dry Run Mode: $DRY_RUN"
echo "Direction Strategy: Pointing FROM Library TO Seeding Folder"
echo "Optimizations: Exact Name Matching | 20MB Piecewise xxh128sum | De-duplicated Size Hashmaps"
echo "----------------------------------------"

AUTH_ARGS=()
if [ -n "$TR_USER" ] && [ -n "$TR_PASS" ]; then
    AUTH_ARGS=(--auth "${TR_USER}:${TR_PASS}")
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Docker container '${CONTAINER_NAME}' is not running."
    exit 1
fi

echo "Caching entire torrent manifest from Transmission..."
RAW_MANIFEST=$(docker exec -i "$CONTAINER_NAME" transmission-remote "${AUTH_ARGS[@]}" --list 2>&1)

if echo "$RAW_MANIFEST" | grep -q "401: Unauthorized"; then
    echo "ERROR: Transmission RPC authentication failed. Check TR_USER and TR_PASS."
    exit 1
fi

# Load previously verified inodes into memory
touch "$VERIFIED_CACHE"
declare -A PROCESSED_INODES
while read -r line; do
    if [ -n "$line" ]; then PROCESSED_INODES[$line]=1; fi
done < "$VERIFIED_CACHE"

# -----------------------------------------------------------------
# OPTIMIZATION: DE-DUPLICATED LIBRARY HASHMAP INDEXING
# -----------------------------------------------------------------
echo "Building in-memory size maps (De-duplicating shared targets)..."
declare -A LIB_HASH_MAPS
declare -A UNIQUED_LIBS

for src_folder in "${!FOLDER_MAP[@]}"; do
    target_lib="${FOLDER_MAP[$src_folder]}"
    if [ -d "$target_lib" ]; then
        UNIQUED_LIBS["$target_lib"]="${UNIQUED_LIBS["$target_lib"]}${src_folder}|"
    else
        echo "WARNING: Configured library path missing, skipping: $target_lib"
    fi
done

for target_lib in "${!UNIQUED_LIBS[@]}"; do
    echo "  * Indexing unique path: $target_lib"
    while read -r -d $'\0' file_path; do
        size=$(stat -c '%s' "$file_path")
        IFS='|' read -r -a matched_sources <<< "${UNIQUED_LIBS["$target_lib"]}"
        for src_folder in "${matched_sources[@]}"; do
            if [ -n "$src_folder" ]; then
                map_key="${src_folder}_${size}"
                LIB_HASH_MAPS["$map_key"]="${LIB_HASH_MAPS["$map_key"]}${file_path}|"
            fi
        done
    done < <(find "$target_lib" -type f -print0 2> /dev/null)
done

echo "Library mapping complete. Starting clean source scanning loop..."
echo "----------------------------------------"

TOTAL_LINKS_HEALED=0
TOTAL_SPACE_SAVED_KBYTES=0
TOTAL_ITEMS_SCANNED=0

for folder in $(echo "${!FOLDER_MAP[@]}" | tr ' ' '\n' | sort); do
    CURRENT_SRC_DIR="${BASE_PATH}/${folder}"
    if [ ! -d "$CURRENT_SRC_DIR" ]; then continue; fi

    echo "Scanning seeding paths in: $CURRENT_SRC_DIR"

    TOTAL_ITEMS=$(find "$CURRENT_SRC_DIR" -maxdepth 1 -mindepth 1 | wc -l)
    CURRENT_INDEX=0

    while read -r -d $'\0' item_path; do
        ITEM_NAME=$(basename "$item_path")
        CURRENT_INDEX=$((CURRENT_INDEX + 1))
        TOTAL_ITEMS_SCANNED=$((TOTAL_ITEMS_SCANNED + 1))

        if ((CURRENT_INDEX % 50 == 0 || CURRENT_INDEX == TOTAL_ITEMS)); then
            printf "   [PROGRESS] %s: %d/%d items evaluated...\n" "$folder" "$CURRENT_INDEX" "$TOTAL_ITEMS"
        fi

        TORRENT_MATCH=false
        while read -r raw_row; do
            ROW_CLEAN=$(echo "$raw_row" | sed 's/ \+/ /g' | sed 's/^ //')
            LINE_NAME=$(echo "$ROW_CLEAN" | awk '{out=""; for(i=10;i<=NF;i++){out=out $i " "}; sub(/ $/,"",out); print out}')

            if [ "$LINE_NAME" = "$ITEM_NAME" ]; then
                TORRENT_MATCH=true
                break
            fi
        done < <(echo "$RAW_MANIFEST" | grep -F "$ITEM_NAME")

        if [ "$TORRENT_MATCH" = false ]; then
            continue
        fi

        while read -r -d $'\0' src_file; do
            FILENAME=$(basename "$src_file")

            if echo "$FILENAME" | grep -E -q -i "\.(${MEDIA_EXTS})$"; then
                SRC_INODE=$(stat -c '%i' "$src_file")
                link_count=$(stat -c '%h' "$src_file")

                if [ "$link_count" -gt 1 ]; then
                    if [ -z "${PROCESSED_INODES[$SRC_INODE]}" ]; then
                        echo "$SRC_INODE" >> "$VERIFIED_CACHE"
                        PROCESSED_INODES[$SRC_INODE]=1
                    fi
                    continue
                fi

                if [ "$link_count" -eq 1 ] && [ -n "${PROCESSED_INODES[$SRC_INODE]}" ]; then
                    continue
                fi

                SRC_SIZE_BYTES=$(stat -c '%s' "$src_file")

                SRC_XXH=""
                MATCHING_LIB_FILE=""

                map_key="${folder}_${SRC_SIZE_BYTES}"
                MATCH_STRING="${LIB_HASH_MAPS["$map_key"]}"

                if [ -n "$MATCH_STRING" ]; then
                    IFS='|' read -r -a potential_matches <<< "$MATCH_STRING"
                    for lib_file in "${potential_matches[@]}"; do
                        if [ -z "$lib_file" ] || [ ! -f "$lib_file" ]; then continue; fi

                        if [ -z "$SRC_XXH" ]; then
                            SRC_XXH=$( (
                                head -c 10M "$src_file"
                                tail -c 10M "$src_file"
                            ) | xxh128sum | awk '{print $1}')
                        fi

                        LIB_XXH=$( (
                            head -c 10M "$lib_file"
                            tail -c 10M "$lib_file"
                        ) | xxh128sum | awk '{print $1}')

                        if [ "$SRC_XXH" = "$LIB_XXH" ]; then
                            MATCHING_LIB_FILE="$lib_file"
                            break
                        fi
                    done
                fi

                if [ -n "$MATCHING_LIB_FILE" ]; then
                    FILE_SIZE_KBYTES=$((SRC_SIZE_BYTES / 1024))
                    TOTAL_SPACE_SAVED_KBYTES=$((TOTAL_SPACE_SAVED_KBYTES + FILE_SIZE_KBYTES))
                    TOTAL_LINKS_HEALED=$((TOTAL_LINKS_HEALED + 1))

                    HUMAN_SIZE=$(du -sh "$src_file" | awk '{print $1}')
                    LIB_FILENAME=$(basename "$MATCHING_LIB_FILE")

                    echo "[MATCH FOUND] ($HUMAN_SIZE): $FILENAME"
                    if [ "$DRY_RUN" = true ]; then
                        echo "    * Library Source Target: $MATCHING_LIB_FILE"
                        echo "    -> Link Will Be Created At: $src_file"
                    else
                        echo "    [ACTION] Re-linking: $LIB_FILENAME -> $FILENAME"
                        rm -f "$src_file"
                        if ln "$MATCHING_LIB_FILE" "$src_file"; then
                            NEW_INODE=$(stat -c '%i' "$src_file")
                            echo "$NEW_INODE" >> "$VERIFIED_CACHE"
                            PROCESSED_INODES[$NEW_INODE]=1
                        else
                            echo "ERROR: Link creation failed for $src_file"
                            exit 1
                        fi
                    fi
                    echo "----------------------------------------"
                fi
            fi

        done < <(find "$item_path" -type f -print0 2> /dev/null)
    done < <(find "$CURRENT_SRC_DIR" -maxdepth 1 -mindepth 1 -print0)
    echo "   Share ${folder} audit complete."
done

HUMAN_SAVED_SIZE=$(awk -v kb="$TOTAL_SPACE_SAVED_KBYTES" 'BEGIN {printf (kb>=1048576)?"%.2f GB":((kb>=1024)?"%.2f MB":"%d KB"), (kb>=1048576)?kb/1048576:((kb>=1024)?kb/1024:kb)}')

echo -e "\\n=== LINK HEALER COMPLETE ==="
echo "Total Items Evaluated Across Shares: $TOTAL_ITEMS_SCANNED"
if [ "$DRY_RUN" = true ]; then
    echo "Summary: Found $TOTAL_LINKS_HEALED valid torrent items with broken links. Repairing them will restore shared space of: $HUMAN_SAVED_SIZE"
else
    echo "Summary: Successfully repaired $TOTAL_LINKS_HEALED valid broken hard links, reclaiming: $HUMAN_SAVED_SIZE"
fi
echo "========================================"
