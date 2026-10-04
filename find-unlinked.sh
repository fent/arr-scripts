#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: MISSING HARD LINK FINDER
# ==============================================================================
# PURPOSE:
#   Scans download folders (matched by name, substring, or glob) for video
#   files that have NOT been hard-linked into a target series media folder.
#   These are episodes that were downloaded but never imported by Sonarr/Radarr,
#   or whose library entry was deleted after import.
#
# HOW IT WORKS:
#   1. Searches the downloads root for folders matching your --search terms.
#   2. Indexes all video file inodes currently in the target media series folder.
#   3. Walks every matched download folder and flags files whose inode is absent
#      from the media index — meaning no hard link exists in the library.
#
# USAGE:
#   ./find-unlinked.sh \
#       -d /mnt/user/data/downloads/tv \
#       -m /mnt/user/data/media/tv/MyShow \
#       -s "MyShow" "My.Show"
#
# USE CASE:
#   Identify which specific episodes in your download folders are missing from
#   the media library so they can be re-imported or investigated.
# ==============================================================================

DOWNLOADS_DIR=""
MEDIA_DIR=""
SEARCH_TERMS=()

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
    -d | --downloads)
        DOWNLOADS_DIR="$2"
        shift 2
        ;;
    -m | --media)
        MEDIA_DIR="$2"
        shift 2
        ;;
    -s | --search)
        shift
        while [[ "$#" -gt 0 ]] && [[ "$1" != -* ]]; do
            SEARCH_TERMS+=("$1")
            shift
        done
        ;;
    *)
        echo "Unknown parameter passed: $1"
        exit 1
        ;;
    esac
done

if [[ -z "$DOWNLOADS_DIR" ]] || [[ -z "$MEDIA_DIR" ]] || [[ ${#SEARCH_TERMS[@]} -eq 0 ]]; then
    echo "Usage: $0 -d /downloads/path -m /media/path -s term1 term2"
    exit 1
fi

DOWNLOADS_DIR=$(realpath "$DOWNLOADS_DIR")
MEDIA_DIR=$(realpath "$MEDIA_DIR")

if [ ! -d "$DOWNLOADS_DIR" ]; then
    echo "Error: Download root directory not found: $DOWNLOADS_DIR"
    exit 1
fi
if [ ! -d "$MEDIA_DIR" ]; then
    echo "Error: Series media directory not found: $MEDIA_DIR"
    exit 1
fi

# 1. Resolve matching download directories
declare -A MATCHED_DIRS_MAP
while IFS= read -r -d $'\0' d; do
    name=$(basename "$d")
    name_lower="${name,,}"

    for term in "${SEARCH_TERMS[@]}"; do
        term_lower="${term,,}"
        # glob match
        if [[ "$name_lower" == "$term_lower" ]] || [[ "$name_lower" == *"$term_lower"* ]]; then
            MATCHED_DIRS_MAP["$d"]=1
            break
        fi
    done
done < <(find "$DOWNLOADS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

if [ ${#MATCHED_DIRS_MAP[@]} -eq 0 ]; then
    echo "No directories in '$DOWNLOADS_DIR' matched your search terms: ${SEARCH_TERMS[*]}"
    exit 0
fi

# Sort matched dirs
mapfile -t MATCHED_DIRS < <(printf "%s\n" "${!MATCHED_DIRS_MAP[@]}" | sort)

echo "Matched ${#MATCHED_DIRS[@]} download folder(s):"
for d in "${MATCHED_DIRS[@]}"; do
    [ -z "$d" ] && continue
    echo "  [+] $(basename "$d")"
done
echo ""

# 2. Index inodes in media directory
echo "Indexing media directory:"
echo "  -> $MEDIA_DIR"

declare -A IMPORTED_INODES
while IFS= read -r -d $'\0' f; do
    ext="${f##*.}"
    ext="${ext,,}"
    if [[ "$ext" =~ ^(mkv|mp4|avi|ts)$ ]]; then
        ino=$(stat -c '%i' "$f" 2> /dev/null)
        if [ -n "$ino" ]; then
            IMPORTED_INODES[$ino]=1
        fi
    fi
done < <(find "$MEDIA_DIR" -type f -print0 2> /dev/null)

IMPORTED_COUNT=${#IMPORTED_INODES[@]}
format_num "$IMPORTED_COUNT" IMPORTED_COUNT_FMT
echo "  Found $IMPORTED_COUNT_FMT existing video files in this series."
echo ""

# 3. Only scan matched download folders
declare -a UNLINKED
scanned_count=0

for dl_dir in "${MATCHED_DIRS[@]}"; do
    [ -z "$dl_dir" ] && continue
    while IFS= read -r -d $'\0' f; do
        ext="${f##*.}"
        ext="${ext,,}"
        if [[ "$ext" =~ ^(mkv|mp4|avi|ts)$ ]]; then
            scanned_count=$((scanned_count + 1))
            ino=$(stat -c '%i' "$f" 2> /dev/null)
            if [ -n "$ino" ] && [ -z "${IMPORTED_INODES[$ino]}" ]; then
                UNLINKED+=("$f")
            fi
        fi
    done < <(find "$dl_dir" -type f -print0 2> /dev/null)
done

format_num "$scanned_count" scanned_count_FMT
echo "Scanned $scanned_count_FMT files across matched download folders."
echo ""

if [ $UNLINKED_COUNT -eq 0 ]; then
    echo "Everything in the matched download folders is already hardlinked to the series folder."
    exit 0
fi

UNLINKED_COUNT=${#UNLINKED[@]}
format_num "$UNLINKED_COUNT" UNLINKED_COUNT_FMT
echo "=== Found $UNLINKED_COUNT_FMT Unlinked Video File(s) ==="
for f in "${UNLINKED[@]}"; do
    size_bytes=$(stat -c '%s' "$f" 2> /dev/null || echo 0)
    size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b / (1024^3) }')
    echo "  [MISSING] $(basename "$f") (${size_gb} GB)"
    echo "    Path: $f"
    echo ""
done
