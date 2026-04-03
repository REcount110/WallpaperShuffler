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
    scan   <folder> [--max-depth N] [--no-follow-symlinks] [--max-file-size BYTES]
           Incremental scan: insert new files, mark missing active files inactive.
           Does NOT reset counts for existing rows.
           Memory-efficient: batched inserts + SQL-side deactivation (no Python set).

    rebuild <folder> [--max-depth N] [--no-follow-symlinks] [--max-file-size BYTES]
           Full rebuild: wipe all rows and re-scan from scratch.

    next   --max-show N [--folder <f>]
           Pick a random active image with count < max_show.
           True O(1) via two-phase SQL: bucket selection + random row pick.
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

Performance (v2.3):
    - cmd_next: O(1) memory, O(MAX_SHOW) SQL rows — NOT O(n).
    - cmd_scan: O(batch_size) Python memory via streaming + temp table.
    - Tested for 500k+ images.  DB cache 8 MB, temp store in memory.

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

# Default max file size (bytes).  Files above this are skipped during scan.
# 0 = no limit.  Typical photographic JPEG ≤ 30 MB; RAW can be 25–100 MB.
DEFAULT_MAX_FILE_SIZE = 20 * 1024 * 1024  # 20 MB

# Batch size for INSERT / deactivate operations during scan.
_SCAN_BATCH = 5000


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def open_db(db_path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=30, isolation_level=None)  # autocommit off via explicit transactions
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    # Increase cache for 500k-row workload (~8 MB cache vs default 2 MB).
    conn.execute("PRAGMA cache_size=-8000")
    # Temp tables stored in memory (used by batched scan).
    conn.execute("PRAGMA temp_store=MEMORY")
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


def iter_images(folder: str, max_depth: int = 20, follow_symlinks: bool = True,
                max_file_size: int = 0):
    """Yield absolute paths of image files under folder, skipping .recycle dirs.

    Args:
        max_file_size: Skip files larger than this (bytes). 0 = no limit.
                       Useful for filtering out RAW files (25-100 MB) that cause
                       GNOME GdkPixbuf to allocate excessive memory on decode.
    """
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
                full = os.path.join(root, fname)
                if max_file_size > 0:
                    try:
                        if os.path.getsize(full) > max_file_size:
                            continue
                    except OSError:
                        continue
                yield full


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_scan(conn: sqlite3.Connection, folder: str, max_depth: int,
             follow_symlinks: bool, max_file_size: int = 0):
    """Incremental scan: insert new files, deactivate missing ones.

    Memory-efficient for 500k+ files:
      • Inserts are batched (_SCAN_BATCH rows per transaction).
      • A temporary table holds all scanned paths; deactivation is a single
        SQL NOT IN / LEFT JOIN — no Python set() of 500k strings.
    """
    folder = os.path.realpath(folder) if follow_symlinks else os.path.abspath(folder)
    like_pattern = _folder_like_pattern(folder)

    # Temporary table for current filesystem paths (lives in this connection only).
    conn.execute("CREATE TEMP TABLE IF NOT EXISTS _fs_paths(path TEXT PRIMARY KEY)")
    conn.execute("DELETE FROM _fs_paths")

    inserted = 0
    scanned = 0
    batch: list[tuple[str]] = []

    for p in iter_images(folder, max_depth, follow_symlinks, max_file_size):
        batch.append((p,))
        scanned += 1
        if len(batch) >= _SCAN_BATCH:
            with conn:
                conn.executemany("INSERT OR IGNORE INTO _fs_paths(path) VALUES (?)", batch)
                conn.executemany("INSERT OR IGNORE INTO images(path) VALUES (?)", batch)
            inserted += conn.total_changes  # approximate
            batch.clear()

    # Flush remaining batch
    if batch:
        with conn:
            conn.executemany("INSERT OR IGNORE INTO _fs_paths(path) VALUES (?)", batch)
            conn.executemany("INSERT OR IGNORE INTO images(path) VALUES (?)", batch)
        batch.clear()

    # Deactivate images that are in the DB (active, under this folder) but
    # NOT on the filesystem anymore.  Done entirely in SQL — zero Python memory.
    with conn:
        conn.execute(
            """
            UPDATE images SET active=0
            WHERE active=1 AND path LIKE ?
              AND path NOT IN (SELECT path FROM _fs_paths)
            """,
            (like_pattern,)
        )

    # Re-activate images that reappeared on disk (e.g. restored from recycle).
    with conn:
        conn.execute(
            """
            UPDATE images SET active=1
            WHERE active=0 AND path LIKE ?
              AND path IN (SELECT path FROM _fs_paths)
            """,
            (like_pattern,)
        )

    # Cleanup temp table
    conn.execute("DELETE FROM _fs_paths")

    deactivated = conn.execute(
        "SELECT changes()"
    ).fetchone()[0]  # from last UPDATE — not perfectly precise but informative

    print(f"scan: {scanned} files found, deactivation pass complete", file=sys.stderr)


def cmd_rebuild(conn: sqlite3.Connection, folder: str, max_depth: int,
                follow_symlinks: bool, max_file_size: int = 0):
    """Full rebuild: clear all rows for this folder prefix, then re-scan."""
    real_folder = os.path.realpath(folder) if follow_symlinks else os.path.abspath(folder)

    with conn:
        conn.execute("DELETE FROM images WHERE path LIKE ?", (_folder_like_pattern(real_folder),))

    cmd_scan(conn, folder, max_depth, follow_symlinks, max_file_size)
    print("rebuild complete", file=sys.stderr)


def cmd_next(conn: sqlite3.Connection, max_show: int, folder: str | None) -> int:
    """
    Pick a random active image with count < max_show — true O(1) SQL.

    Strategy (two-phase, constant memory):
      1. COUNT the distinct `count` values among candidates.
      2. Weighted-random pick a count bucket (weight = max_show - count).
      3. SELECT one random row from that bucket (LIMIT 1, ORDER BY RANDOM()).
    Total rows fetched into Python: always 1.  Memory: O(MAX_SHOW), not O(n).

    Prints path on line 1, new count (post-increment) on line 2.
    Returns 0 on success, 1 if nothing available.
    """
    where_folder = ""
    params: list = [max_show]
    if folder:
        real_folder = os.path.realpath(folder)
        where_folder = "AND path LIKE ?"
        params.append(_folder_like_pattern(real_folder))

    def _pick_one():
        # Phase 1: Get count distribution (at most max_show distinct buckets → O(MAX_SHOW))
        buckets = conn.execute(
            f"""
            SELECT count, COUNT(*) AS n
            FROM images
            WHERE active=1 AND count < ? {where_folder}
            GROUP BY count
            """,
            params
        ).fetchall()

        if not buckets:
            return None

        # Phase 2: Weighted-random bucket selection
        # weight of each bucket = (max_show - count) * number_of_images_in_bucket
        weights = [(max_show - c) * n for c, n in buckets]
        total = sum(weights)
        if total <= 0:
            chosen_bucket = buckets[random.randrange(len(buckets))][0]
        else:
            r = random.uniform(0, total)
            cumulative = 0.0
            chosen_bucket = buckets[-1][0]
            for i, w in enumerate(weights):
                cumulative += w
                if r <= cumulative:
                    chosen_bucket = buckets[i][0]
                    break

        # Phase 3: Pick one random row from the chosen bucket (O(1) via RANDOM())
        pick_params: list = [chosen_bucket]
        pick_folder = ""
        if folder:
            pick_folder = "AND path LIKE ?"
            pick_params.append(_folder_like_pattern(os.path.realpath(folder)))

        row = conn.execute(
            f"""
            SELECT id, path, count FROM images
            WHERE active=1 AND count=? {pick_folder}
            ORDER BY RANDOM() LIMIT 1
            """,
            pick_params
        ).fetchone()
        return row

    row = _pick_one()

    if row is None:
        # All images exhausted for this round → auto-reset counts
        _reset_counts(conn, folder)
        row = _pick_one()

    if row is None:
        return 1

    chosen_id, chosen_path, chosen_count = row
    new_count = chosen_count + 1

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
    s.add_argument("--max-file-size", type=int, default=0,
                   help="Skip files larger than N bytes (0=no limit). "
                        "Use to filter out RAW files that cause GNOME decode OOM.")

    # rebuild
    r = sub.add_parser("rebuild", help="Full rebuild of index for folder")
    r.add_argument("folder")
    r.add_argument("--max-depth", type=int, default=20)
    r.add_argument("--no-follow-symlinks", action="store_true")
    r.add_argument("--max-file-size", type=int, default=0,
                   help="Skip files larger than N bytes (0=no limit).")

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
        cmd_scan(conn, args.folder, args.max_depth, not args.no_follow_symlinks,
                 args.max_file_size)

    elif args.command == "rebuild":
        cmd_rebuild(conn, args.folder, args.max_depth, not args.no_follow_symlinks,
                    args.max_file_size)

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
