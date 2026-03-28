#!/usr/bin/env python3
"""
playlist_index.py — SQLite-backed image index for photography_wallpaper_shuffler_v2.

Schema:
    images(
        id         INTEGER PRIMARY KEY,
        path       TEXT    UNIQUE NOT NULL,
        count      INTEGER NOT NULL DEFAULT 0,
        last_shown INTEGER NOT NULL DEFAULT 0,   -- unix timestamp
        active     INTEGER NOT NULL DEFAULT 1    -- 1=available, 0=recycled/deleted
    )

Commands:
    scan   <folder> [--max-depth N] [--follow-symlinks]
           Incremental scan: insert new files, mark missing active files inactive.
           Does NOT reset counts for existing rows.

    rebuild <folder> [--max-depth N] [--follow-symlinks]
           Full rebuild: wipe all rows and re-scan from scratch.

    next   --max-show N [--folder <f>]
           Pick a random active image with count < max_show.
           Uses weighted random via (max_show - count) to prefer less-shown images.
           Atomically increments count.
           Prints path on line 1, new count on line 2 (exit 1 if none available).

    mark-inactive <path>
           Mark a specific path as inactive (recycled / deleted externally).

    mark-active <path>
           Re-activate a previously inactive path.

    stats  [--folder <f>]
           Print counts by status to stderr.

    reset-counts [--folder <f>]
           Reset all counts to 0 for active images (triggers a fresh round).

Usage:
    python3 playlist_index.py --db /path/to/index.db <command> [args]

Environment:
    PLAYLIST_INDEX_DB — default DB path (overridden by --db).
"""

import argparse
import os
import sqlite3
import sys
import time
import random
from pathlib import Path

# ---------------------------------------------------------------------------
# Image extensions (case-insensitive via .lower())
# ---------------------------------------------------------------------------
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".tga", ".webp", ".bmp"}


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def open_db(db_path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10, isolation_level=None)  # autocommit off via explicit transactions
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS images (
            id         INTEGER PRIMARY KEY,
            path       TEXT    UNIQUE NOT NULL,
            count      INTEGER NOT NULL DEFAULT 0,
            last_shown INTEGER NOT NULL DEFAULT 0,
            active     INTEGER NOT NULL DEFAULT 1
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_active_count ON images(active, count)")
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# File system scan helpers
# ---------------------------------------------------------------------------

def _folder_like_pattern(folder: str) -> str:
    """Return a LIKE pattern matching all paths directly under folder.
    Uses 'folder/' prefix to avoid false-matching sibling dirs with the
    same prefix (e.g. /photos matching /photos_backup).
    """
    return folder.rstrip(os.sep) + os.sep + "%"


def iter_images(folder: str, max_depth: int = 20, follow_symlinks: bool = True):
    """Yield absolute paths of image files under folder, skipping .recycle dirs."""
    folder = os.path.realpath(folder) if follow_symlinks else os.path.abspath(folder)
    recycle = os.path.join(folder, ".recycle")

    for root, dirs, files in os.walk(folder, followlinks=follow_symlinks):
        # Prune recycle dir (exact match only) and limit depth.
        # Using == instead of startswith() avoids false-pruning sibling dirs
        # that share the same prefix (e.g. .recycle_old).
        depth = root[len(folder):].count(os.sep)
        dirs[:] = [
            d for d in dirs
            if os.path.join(root, d) != recycle
            and depth < max_depth
        ]
        for fname in files:
            if Path(fname).suffix.lower() in IMAGE_EXTS:
                yield os.path.join(root, fname)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_scan(conn: sqlite3.Connection, folder: str, max_depth: int, follow_symlinks: bool):
    """Incremental scan: insert new files, deactivate missing ones."""
    folder = os.path.realpath(folder) if follow_symlinks else os.path.abspath(folder)

    # Collect all current filesystem paths under folder
    fs_paths = set(iter_images(folder, max_depth, follow_symlinks))

    with conn:
        # Insert new paths (ignore if already present; count defaults to 0).
        conn.executemany(
            "INSERT OR IGNORE INTO images(path) VALUES (?)",
            [(p,) for p in fs_paths]
        )

        # Deactivate rows that belong to this folder but no longer exist on disk.
        # Use folder + "/" prefix to avoid matching sibling directories with the
        # same path prefix (e.g. /photos matching /photos_backup).
        rows = conn.execute(
            "SELECT id, path FROM images WHERE active=1 AND path LIKE ?",
            (_folder_like_pattern(folder),)
        ).fetchall()
        deactivate_ids = [row[0] for row in rows if row[1] not in fs_paths]
        if deactivate_ids:
            conn.executemany(
                "UPDATE images SET active=0 WHERE id=?",
                [(i,) for i in deactivate_ids]
            )

    new_count = len(fs_paths)
    deactivated = len(deactivate_ids) if deactivate_ids else 0
    print(f"scan: {new_count} files found, {deactivated} deactivated", file=sys.stderr)


def cmd_rebuild(conn: sqlite3.Connection, folder: str, max_depth: int, follow_symlinks: bool):
    """Full rebuild: clear all rows for this folder prefix, then re-scan."""
    real_folder = os.path.realpath(folder) if follow_symlinks else os.path.abspath(folder)

    with conn:
        conn.execute("DELETE FROM images WHERE path LIKE ?", (_folder_like_pattern(real_folder),))

    cmd_scan(conn, folder, max_depth, follow_symlinks)
    print("rebuild complete", file=sys.stderr)


def cmd_next(conn: sqlite3.Connection, max_show: int, folder: str | None) -> int:
    """
    Pick a random active image with count < max_show.
    Uses weighted reservoir: weight = (max_show - count), so rarely-shown images
    are preferred over near-expiry ones, while still being random.

    Prints path on line 1, new count (post-increment) on line 2.
    Returns 0 on success, 1 if nothing available.
    """
    where_folder = ""
    params: list = [max_show]
    if folder:
        real_folder = os.path.realpath(folder)
        where_folder = "AND path LIKE ?"
        params.append(_folder_like_pattern(real_folder))

    def _fetch():
        return conn.execute(
            f"""
            SELECT id, path, count, ({max_show} - count) AS weight
            FROM images
            WHERE active=1 AND count < ? {where_folder}
            """,
            params
        ).fetchall()

    rows = _fetch()

    if not rows:
        # All images exhausted for this round → auto-reset counts
        _reset_counts(conn, folder)
        rows = _fetch()

    if not rows:
        return 1

    # Weighted random selection (prefer images with lower count)
    ids, paths, counts, weights = zip(*rows)
    total = sum(weights)
    if total <= 0:
        chosen_idx = random.randrange(len(rows))
    else:
        r = random.uniform(0, total)
        cumulative = 0.0
        chosen_idx = len(rows) - 1
        for i, w in enumerate(weights):
            cumulative += w
            if r <= cumulative:
                chosen_idx = i
                break

    chosen_id = ids[chosen_idx]
    chosen_path = paths[chosen_idx]
    new_count = counts[chosen_idx] + 1

    # Atomically increment count and record last_shown
    now = int(time.time())
    with conn:
        conn.execute(
            "UPDATE images SET count=count+1, last_shown=? WHERE id=?",
            (now, chosen_id)
        )

    # Shell reads both values: IFS= read -r photo; IFS= read -r local_newcount
    print(chosen_path)
    print(new_count)
    return 0


def _reset_counts(conn: sqlite3.Connection, folder: str | None):
    """Reset counts to 0 for all active images (optionally scoped to folder)."""
    if folder:
        real_folder = os.path.realpath(folder)
        with conn:
            conn.execute(
                "UPDATE images SET count=0 WHERE active=1 AND path LIKE ?",
                (_folder_like_pattern(real_folder),)
            )
    else:
        with conn:
            conn.execute("UPDATE images SET count=0 WHERE active=1")


def cmd_mark_inactive(conn: sqlite3.Connection, path: str):
    real = os.path.realpath(path)
    with conn:
        conn.execute("UPDATE images SET active=0 WHERE path=?", (real,))
    print(f"marked inactive: {real}", file=sys.stderr)


def cmd_mark_active(conn: sqlite3.Connection, path: str):
    """Activate a path. UPSERT: inserts the row if it doesn't exist yet."""
    real = os.path.realpath(path)
    with conn:
        # INSERT OR IGNORE ensures the row exists, then UPDATE sets active=1.
        # This handles the case where the path has never been scanned yet.
        conn.execute(
            "INSERT OR IGNORE INTO images(path) VALUES (?)",
            (real,)
        )
        conn.execute("UPDATE images SET active=1 WHERE path=?", (real,))
    print(f"marked active: {real}", file=sys.stderr)


def cmd_stats(conn: sqlite3.Connection, folder: str | None):
    where = ""
    params: list = []
    if folder:
        real_folder = os.path.realpath(folder)
        where = "WHERE path LIKE ?"
        params.append(_folder_like_pattern(real_folder))

    total = conn.execute(f"SELECT COUNT(*) FROM images {where}", params).fetchone()[0]
    active = conn.execute(
        f"SELECT COUNT(*) FROM images {where} {'AND' if where else 'WHERE'} active=1",
        params
    ).fetchone()[0]
    inactive = total - active
    avg_count = conn.execute(
        f"SELECT AVG(count) FROM images {where} {'AND' if where else 'WHERE'} active=1",
        params
    ).fetchone()[0] or 0
    max_count = conn.execute(
        f"SELECT MAX(count) FROM images {where} {'AND' if where else 'WHERE'} active=1",
        params
    ).fetchone()[0] or 0

    print(f"total={total}  active={active}  inactive={inactive}  avg_count={avg_count:.1f}  max_count={max_count}",
          file=sys.stderr)


def cmd_reset_counts(conn: sqlite3.Connection, folder: str | None):
    _reset_counts(conn, folder)
    print("counts reset to 0", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="playlist_index.py",
        description="SQLite-backed image index for wallpaper shuffler."
    )
    p.add_argument("--db", default=os.environ.get("PLAYLIST_INDEX_DB", ""),
                   help="Path to SQLite DB file. Defaults to $PLAYLIST_INDEX_DB.")

    sub = p.add_subparsers(dest="command", required=True)

    # scan
    s = sub.add_parser("scan", help="Incremental scan of folder")
    s.add_argument("folder")
    s.add_argument("--max-depth", type=int, default=20)
    s.add_argument("--no-follow-symlinks", action="store_true")

    # rebuild
    r = sub.add_parser("rebuild", help="Full rebuild of index for folder")
    r.add_argument("folder")
    r.add_argument("--max-depth", type=int, default=20)
    r.add_argument("--no-follow-symlinks", action="store_true")

    # next
    n = sub.add_parser("next", help="Pick next wallpaper")
    n.add_argument("--max-show", type=int, required=True)
    n.add_argument("--folder", default="")

    # mark-inactive
    mi = sub.add_parser("mark-inactive", help="Mark path as inactive")
    mi.add_argument("path")

    # mark-active
    ma = sub.add_parser("mark-active", help="Re-activate a path")
    ma.add_argument("path")

    # stats
    st = sub.add_parser("stats", help="Print index statistics")
    st.add_argument("--folder", default="")

    # reset-counts
    rc = sub.add_parser("reset-counts", help="Reset all counts to 0")
    rc.add_argument("--folder", default="")

    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    db_path = args.db
    if not db_path:
        # Default: same directory as this script (co-located with the shell script)
        db_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.db")

    conn = open_db(db_path)

    if args.command == "scan":
        cmd_scan(conn, args.folder, args.max_depth, not args.no_follow_symlinks)

    elif args.command == "rebuild":
        cmd_rebuild(conn, args.folder, args.max_depth, not args.no_follow_symlinks)

    elif args.command == "next":
        rc = cmd_next(conn, args.max_show, args.folder or None)
        sys.exit(rc)

    elif args.command == "mark-inactive":
        cmd_mark_inactive(conn, args.path)

    elif args.command == "mark-active":
        cmd_mark_active(conn, args.path)

    elif args.command == "stats":
        cmd_stats(conn, args.folder or None)

    elif args.command == "reset-counts":
        cmd_reset_counts(conn, args.folder or None)

    conn.close()


if __name__ == "__main__":
    main()
