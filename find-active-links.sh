#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: HARD LINK AUDIT TOOL
# ==============================================================================
# PURPOSE:
#   Given one or more download folders and a media library directory, this
#   script reports which video files in the download folders still have an
#   active hard link inside the media library and which do not.
#
# HOW IT WORKS:
#   1. Indexes all video files in the media library directory by inode.
#   2. Walks each specified download folder and checks every video file's inode
#      against that index.
#   3. Prints a per-file [STILL LINKED] or [NOT LINKED] result and a summary.
#
# USAGE:
#   ./find-active-links.sh -m /mnt/user/data/media/tv/MyShow \
#       -f /mnt/user/data/downloads/tv/MyShow.S01 /mnt/user/data/downloads/tv/MyShow.S02
#
# USE CASE:
#   Quickly verify whether a particular set of download folders are still
#   referenced by your media library before freeing disk space.
# ==============================================================================

MEDIA_DIR=""
FOLDERS=()

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
    -m | --media)
        MEDIA_DIR="$2"
        shift 2
        ;;
    -f | --folders)
        shift
        while [[ "$#" -gt 0 ]] && [[ "$1" != -* ]]; do
            FOLDERS+=("$1")
            shift
        done
        ;;
    *)
        echo "Unknown parameter passed: $1"
        exit 1
        ;;
    esac
done

if [[ -z "$MEDIA_DIR" ]] || [[ ${#FOLDERS[@]} -eq 0 ]]; then
    echo "Usage: $0 -m /media/path -f /folder1 /folder2"
    exit 1
fi

MEDIA_DIR=$(realpath "$MEDIA_DIR")
if [ ! -d "$MEDIA_DIR" ]; then
    echo "Error: Media directory not found: $MEDIA_DIR"
    exit 1
fi

echo "Indexing media directory:"
echo "  -> $MEDIA_DIR"

declare -A MEDIA_INODES

# Index media inodes
while IFS= read -r -d $'\0' f; do
    ext="${f##*.}"
    ext="${ext,,}" # to lowercase
    if [[ "$ext" =~ ^(mkv|mp4|avi|ts)$ ]]; then
        ino=$(stat -c '%i' "$f" 2> /dev/null)
        if [ -n "$ino" ]; then
            if [[ -n "${MEDIA_INODES[$ino]}" ]]; then
                MEDIA_INODES[$ino]+="|$f"
            else
                MEDIA_INODES[$ino]="$f"
            fi
        fi
    fi
done < <(find "$MEDIA_DIR" -type f -print0 2> /dev/null)

echo "  Indexed ${#MEDIA_INODES[@]} unique video inodes in media library."
echo ""

for folder in "${FOLDERS[@]}"; do
    folder_path=$(realpath "$folder")
    if [ ! -d "$folder_path" ]; then
        echo "Warning: '$folder' is not a valid directory. Skipping."
        echo ""
        continue
    fi

    echo "=================================================="
    echo "Checking: $(basename "$folder_path")"
    echo "Full path: $folder_path"
    echo "=================================================="

    # Pre-cache files
    FILES=()
    while IFS= read -r -d $'\0' f; do
        ext="${f##*.}"
        ext="${ext,,}"
        if [[ "$ext" =~ ^(mkv|mp4|avi|ts)$ ]]; then
            FILES+=("$f")
        fi
    done < <(find "$folder_path" -type f -print0 2> /dev/null)

    if [ ${#FILES[@]} -eq 0 ]; then
        echo "  No video files found in this folder."
        echo ""
        continue
    fi

    linked_count=0
    unlinked_count=0

    # Sort files
    mapfile -t sorted_files < <(printf "%s\n" "${FILES[@]}" | sort)

    for f in "${sorted_files[@]}"; do
        [ -z "$f" ] && continue
        ino=$(stat -c '%i' "$f" 2> /dev/null)
        if [ -z "$ino" ]; then continue; fi

        matches="${MEDIA_INODES[$ino]}"
        fname=$(basename "$f")

        if [ -n "$matches" ]; then
            linked_count=$((linked_count + 1))
            echo "  [STILL LINKED] $fname"
            IFS='|' read -r -a match_arr <<< "$matches"
            for m in "${match_arr[@]}"; do
                rel_path="${m#"$MEDIA_DIR"/}"
                echo "    --> Media: $rel_path"
            done
        else
            unlinked_count=$((unlinked_count + 1))
            echo "  [NOT LINKED]   $fname (No links found in target media folder)"
        fi
    done

    echo ""
    echo "Summary for '$(basename "$folder_path")':"
    format_num "$linked_count" linked_count_FMT
    echo "  - Active links in media: $linked_count_FMT"
    format_num "$unlinked_count" unlinked_count_FMT
    echo "  - Unlinked / abandoned : $unlinked_count_FMT"
    echo ""
done
