#!/usr/bin/env python3

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
#   python3 find_unlinked.py \
#       -d /mnt/user/data/downloads/tv \
#       -m /mnt/user/data/media/tv/MyShow \
#       -s "MyShow" "My.Show"
#
# USE CASE:
#   Identify which specific episodes in your download folders are missing from
#   the media library so they can be re-imported or investigated.
# ==============================================================================

import argparse
import fnmatch
import sys
from pathlib import Path

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".ts"}


def get_inode(p: Path):
    try:
        st = p.stat()
        return (st.st_dev, st.st_ino)
    except OSError:
        return None


def collect_target_dirs(base_download_dir: Path, search_terms: list[str]) -> list[Path]:
    """Find directories in base_download_dir matching any pattern, substring, or exact name."""
    matched = set()

    for entry in base_download_dir.iterdir():
        # Only inspect directories in the download root
        if not entry.is_dir():
            continue

        name = entry.name
        name_lower = name.lower()

        for term in search_terms:
            term_clean = term.strip()
            term_lower = term_clean.lower()

            # 1. Exact or glob/wildcard match (e.g. "*ShowName*")
            if fnmatch.fnmatch(name_lower, term_lower):
                matched.add(entry)
                break
            # 2. Plain substring match (e.g. "ShowName")
            if term_lower in name_lower:
                matched.add(entry)
                break

    return sorted(matched)


def main():
    parser = argparse.ArgumentParser(
        description="Find video files in specific download folders that aren't hardlinked to a series media folder."
    )
    parser.add_argument(
        "-d", "--downloads",
        required=True,
        help="Root downloads directory (e.g., /mnt/user/downloads/complete)"
    )
    parser.add_argument(
        "-m", "--media",
        required=True,
        help="Path to the single target Series folder in media library (e.g., /mnt/user/media/TV/MyShow)"
    )
    parser.add_argument(
        "-s", "--search",
        nargs="+",
        required=True,
        help="One or more folder names, glob patterns, or substrings to match inside downloads"
    )

    args = parser.parse_args()

    downloads_root = Path(args.downloads).resolve()
    media_dir = Path(args.media).resolve()

    if not downloads_root.is_dir():
        print(f"Error: Download root directory not found: {downloads_root}")
        sys.exit(1)
    if not media_dir.is_dir():
        print(f"Error: Series media directory not found: {media_dir}")
        sys.exit(1)

    # 1. Resolve matching download directories
    matched_download_dirs = collect_target_dirs(downloads_root, args.search)

    if not matched_download_dirs:
        print(f"No directories in '{downloads_root}' matched your search terms: {args.search}")
        sys.exit(0)

    print(f"Matched {len(matched_download_dirs)} download folder(s):")
    for d in matched_download_dirs:
        print(f"  [+] {d.name}")
    print()

    # 2. Index all current inodes in the single series media directory
    print(f"Indexing media directory:\n  -> {media_dir}")
    imported_inodes = set()
    for f in media_dir.rglob("*"):
        if f.is_file() and f.suffix.lower() in VIDEO_EXTS:
            ino = get_inode(f)
            if ino:
                imported_inodes.add(ino)

    print(f"  Found {len(imported_inodes)} existing video files in this series.\n")

    # 3. Only scan the matched download folders
    unlinked = []
    scanned_count = 0

    for dl_dir in matched_download_dirs:
        for f in dl_dir.rglob("*"):
            if f.is_file() and f.suffix.lower() in VIDEO_EXTS:
                scanned_count += 1
                ino = get_inode(f)
                if ino and ino not in imported_inodes:
                    unlinked.append(f)

    print(f"Scanned {scanned_count} files across matched download folders.\n")

    if not unlinked:
        print("Everything in the matched download folders is already hardlinked to the series folder.")
        return

    print(f"=== Found {len(unlinked)} Unlinked Video File(s) ===")
    for f in unlinked:
        size_gb = f.stat().st_size / (1024**3)
        print(f"  [MISSING] {f.name} ({size_gb:.2f} GB)")
        print(f"    Path: {f}")
        print()


if __name__ == "__main__":
    main()
