#!/bin/bash

# ==============================================================================
# SCRIPT DESCRIPTION: HARD LINK AUDIT AND DISCOVERY TOOL
# ==============================================================================
# PURPOSE:
#   Scans download folders against a media library directory to report which
#   video files still have active hard links into the media library and which
#   do not (missing/unlinked).
#
# USAGE:
#   # Check specific folder(s):
#   ./check-hardlinks.sh -m /media/tv/MyShow -d /downloads/tv/MyShow.S01 /downloads/tv/MyShow.S02
#
#   # Search terms under a download root (e.g. filtering many season folders for the same show):
#   ./check-hardlinks.sh -m /media/tv/MyShow -d /downloads/tv -s "MyShow" "My.Show"
#
#   # Filter options:
#   ./check-hardlinks.sh -m /media/tv/MyShow -d /downloads/tv/MyShow.S01 --unlinked-only
#   ./check-hardlinks.sh -m /media/tv/MyShow -d /downloads/tv/MyShow.S01 --linked-only
# ==============================================================================

set -o pipefail

MEDIA_DIR=""
DOWNLOAD_PATHS=()
SEARCH_TERMS=()
FILTER="all" # "all", "unlinked", or "linked"

# Color support
if [ -t 1 ]; then
    COLOR_GREEN=$'\033[32m'
    COLOR_RED=$'\033[31m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_RESET=""
fi

# Fast pure-bash function to format numbers with commas
format_num() {
    local n=$1 res=""
    while [ ${#n} -gt 3 ]; do
        res=",${n: -3}${res}"
        n="${n:0:${#n}-3}"
    done
    printf -v "$2" "%s" "${n}${res}"
}

usage() {
    cat << EOF
Usage: $0 -m <media_path> -d <download_path...> [-s <term1> <term2> ...] [options]

Required:
  -m, --media <path>            Target media library directory
  -d, --downloads <paths...>    One or more download directories or download root folders

Optional Search / Filter:
  -s, --search <terms...>       Filter/match subdirectories or folders by search terms
  -u, --unlinked-only           Only display unlinked/missing files
  -l, --linked-only             Only display still-linked files
  -h, --help                    Show this help message
EOF
    exit "${1:-0}"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
    -m | --media)
        MEDIA_DIR="$2"
        shift 2
        ;;
    -d | --downloads)
        shift
        while [[ "$#" -gt 0 ]] && [[ "$1" != -* ]]; do
            DOWNLOAD_PATHS+=("$1")
            shift
        done
        ;;
    -s | --search)
        shift
        while [[ "$#" -gt 0 ]] && [[ "$1" != -* ]]; do
            SEARCH_TERMS+=("$1")
            shift
        done
        ;;
    -u | --unlinked-only | --unlinked)
        FILTER="unlinked"
        shift
        ;;
    -l | --linked-only | --linked)
        FILTER="linked"
        shift
        ;;
    -h | --help)
        usage 0
        ;;
    *)
        echo "Unknown parameter passed: $1"
        usage 1
        ;;
    esac
done

if [[ -z "$MEDIA_DIR" ]]; then
    echo "Error: Target media directory (-m / --media) is required."
    usage 1
fi

if [[ ${#DOWNLOAD_PATHS[@]} -eq 0 ]]; then
    echo "Error: At least one download path (-d / --downloads) is required."
    usage 1
fi

MEDIA_DIR=$(realpath "$MEDIA_DIR" 2> /dev/null)
if [ ! -d "$MEDIA_DIR" ]; then
    echo "Error: Media directory not found: $MEDIA_DIR"
    exit 1
fi

# Resolve target folders
TARGET_FOLDERS=()

if [[ ${#SEARCH_TERMS[@]} -gt 0 ]]; then
    declare -A MATCHED_MAP
    for p in "${DOWNLOAD_PATHS[@]}"; do
        resolved=$(realpath "$p" 2> /dev/null)
        if [ ! -d "$resolved" ]; then
            echo "Warning: Download path not found, skipping: $p"
            continue
        fi

        # Check subdirectories matching terms
        found_sub=0
        while IFS= read -r -d $'\0' d; do
            name=$(basename "$d")
            name_lower="${name,,}"

            for term in "${SEARCH_TERMS[@]}"; do
                term_lower="${term,,}"
                if [[ "$name_lower" == "$term_lower" ]] || [[ "$name_lower" == *"$term_lower"* ]]; then
                    MATCHED_MAP["$d"]=1
                    found_sub=1
                    break
                fi
            done
        done < <(find "$resolved" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

        # If no subdirectories matched, check if the folder itself matches
        if [ "$found_sub" -eq 0 ]; then
            name=$(basename "$resolved")
            name_lower="${name,,}"
            for term in "${SEARCH_TERMS[@]}"; do
                term_lower="${term,,}"
                if [[ "$name_lower" == "$term_lower" ]] || [[ "$name_lower" == *"$term_lower"* ]]; then
                    MATCHED_MAP["$resolved"]=1
                    break
                fi
            done
        fi
    done

    if [ ${#MATCHED_MAP[@]} -eq 0 ]; then
        echo "No directories matched search terms: ${SEARCH_TERMS[*]}"
        exit 0
    fi

    mapfile -t TARGET_FOLDERS < <(printf "%s\n" "${!MATCHED_MAP[@]}" | sort)
else
    for p in "${DOWNLOAD_PATHS[@]}"; do
        resolved=$(realpath "$p" 2> /dev/null)
        if [ -d "$resolved" ]; then
            TARGET_FOLDERS+=("$resolved")
        else
            echo "Warning: Folder not found, skipping: $p"
        fi
    done
fi

if [[ ${#TARGET_FOLDERS[@]} -eq 0 ]]; then
    echo "Error: No valid target folders to inspect."
    exit 1
fi

echo "Target folders to check (${#TARGET_FOLDERS[@]}):"
for d in "${TARGET_FOLDERS[@]}"; do
    echo "  [+] $(basename "$d")"
done
echo ""

# Index video inodes in media directory
echo "Indexing media directory:"
echo "  -> $MEDIA_DIR"

declare -A MEDIA_INODES

while IFS= read -r -d $'\0' f; do
    ext="${f##*.}"
    ext="${ext,,}"
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

indexed_count=${#MEDIA_INODES[@]}
indexed_count_FMT=""
format_num "$indexed_count" indexed_count_FMT
echo "  Indexed $indexed_count_FMT unique video files in media library."
echo ""

total_scanned=0
total_linked=0
total_unlinked=0

for folder_path in "${TARGET_FOLDERS[@]}"; do
    folder_name=$(basename "$folder_path")
    echo "=================================================="
    echo "Checking: $folder_name"
    echo "Full path: $folder_path"
    echo "=================================================="

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

    folder_linked=0
    folder_unlinked=0

    mapfile -t sorted_files < <(printf "%s\n" "${FILES[@]}" | sort)

    for f in "${sorted_files[@]}"; do
        [ -z "$f" ] && continue
        ino=$(stat -c '%i' "$f" 2> /dev/null)
        if [ -z "$ino" ]; then continue; fi

        matches="${MEDIA_INODES[$ino]}"
        fname=$(basename "$f")
        size_bytes=$(stat -c '%s' "$f" 2> /dev/null || echo 0)
        size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b / (1024^3) }')

        if [ -n "$matches" ]; then
            folder_linked=$((folder_linked + 1))
            if [[ "$FILTER" != "unlinked" ]]; then
                echo "  ${COLOR_GREEN}[STILL LINKED]${COLOR_RESET} $fname (${size_gb} GB)"
                IFS='|' read -r -a match_arr <<< "$matches"
                for m in "${match_arr[@]}"; do
                    rel_path="${m#"$MEDIA_DIR"/}"
                    echo "    --> Media: $rel_path"
                done
            fi
        else
            folder_unlinked=$((folder_unlinked + 1))
            if [[ "$FILTER" != "linked" ]]; then
                echo "  ${COLOR_RED}[NOT LINKED]${COLOR_RESET}   $fname (${size_gb} GB)"
                echo "    --> Path: $f"
            fi
        fi
    done

    total_scanned=$((total_scanned + ${#sorted_files[@]}))
    total_linked=$((total_linked + folder_linked))
    total_unlinked=$((total_unlinked + folder_unlinked))

    echo ""
    echo "Summary for '$folder_name':"
    fl_FMT=""
    format_num "$folder_linked" fl_FMT
    fu_FMT=""
    format_num "$folder_unlinked" fu_FMT
    echo "  - Active links in media: $fl_FMT"
    echo "  - Unlinked / abandoned : $fu_FMT"
    echo ""
done

if [[ ${#TARGET_FOLDERS[@]} -gt 1 ]]; then
    echo "=================================================="
    echo "Overall Summary across ${#TARGET_FOLDERS[@]} folder(s):"
    ts_FMT=""
    format_num "$total_scanned" ts_FMT
    tl_FMT=""
    format_num "$total_linked" tl_FMT
    tu_FMT=""
    format_num "$total_unlinked" tu_FMT
    echo "  - Total video files    : $ts_FMT"
    echo "  - Active links in media: $tl_FMT"
    echo "  - Unlinked / abandoned : $tu_FMT"
    echo "=================================================="
fi
