#!/usr/bin/env python3
import argparse
import sys
from collections import defaultdict
from pathlib import Path

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".ts"}


def get_inode(p: Path):
    try:
        st = p.stat()
        return (st.st_dev, st.st_ino)
    except OSError:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Check if files in specific old download folders still have hard links in the media library."
    )
    parser.add_argument(
        "-m", "--media",
        required=True,
        help="Path to the media series folder (or root media directory) to check against"
    )
    parser.add_argument(
        "-f", "--folders",
        nargs="+",
        required=True,
        help="One or more old download folders to check"
    )

    args = parser.parse_args()

    media_dir = Path(args.media).resolve()
    if not media_dir.is_dir():
        print(f"Error: Media directory not found: {media_dir}")
        sys.exit(1)

    # 1. Index all media files by (device, inode)
    print(f"Indexing media directory:\n  -> {media_dir}")
    media_inode_map = defaultdict(list)
    for f in media_dir.rglob("*"):
        if f.is_file() and f.suffix.lower() in VIDEO_EXTS:
            ino = get_inode(f)
            if ino:
                media_inode_map[ino].append(f)

    print(f"  Indexed {len(media_inode_map)} unique video inodes in media library.\n")

    # 2. Inspect each specified old folder
    for folder_str in args.folders:
        folder_path = Path(folder_str).resolve()
        if not folder_path.is_dir():
            print(f"Warning: '{folder_str}' is not a valid directory. Skipping.\n")
            continue

        print(f"==================================================")
        print(f"Checking: {folder_path.name}")
        print(f"Full path: {folder_path}")
        print(f"==================================================")

        files = [
            f for f in folder_path.rglob("*")
            if f.is_file() and f.suffix.lower() in VIDEO_EXTS
        ]

        if not files:
            print("  No video files found in this folder.\n")
            continue

        linked_count = 0
        unlinked_count = 0

        for f in sorted(files):
            ino = get_inode(f)
            if not ino:
                continue

            matches = media_inode_map.get(ino)

            if matches:
                linked_count += 1
                print(f"  [STILL LINKED] {f.name}")
                for m in matches:
                    print(f"    --> Media: {m.relative_to(media_dir)}")
            else:
                unlinked_count += 1
                print(f"  [NOT LINKED]   {f.name} (No links found in target media folder)")

        print(f"\nSummary for '{folder_path.name}':")
        print(f"  - Active links in media: {linked_count}")
        print(f"  - Unlinked / abandoned : {unlinked_count}\n")


if __name__ == "__main__":
    main()
