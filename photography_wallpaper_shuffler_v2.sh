#!/bin/bash

#*********************************************************************************************************
# Photography wallpaper random shuffle script v2.0
# — Refactored for 100k+ images with O(1) per-iteration cost.
#
# Key changes from v1:
#   1. SQLite-backed image index (playlist_index.py) replaces external COUNT_FILE
#      and plain playlist.txt:
#      - Persistent across reboots: counts/state survive restart without re-scan.
#      - Incremental scan: only new/deleted files update the DB (no full find|shuf).
#      - Weighted random selection: images with lower count are preferred.
#      - O(1) per iteration: single SQL query per wallpaper change.
#      - SQLite is sole source of truth; filenames remain unchanged.
#   2. Fixed should_refresh_list logic inversion bug from v1.
#   3. find -L limited to max-depth 20 to prevent symlink loops.
#   4. Reduced gsettings/dbus calls: picture-options set once; dark variant cached.
#   5. Memory-safe: no bash arrays holding 100k entries.
#   6. USR1 signal triggers immediate index rebuild.
#   7. HUP signal triggers config reload from env file.
#   8. Graceful degradation: per-image errors skip, don't crash.
#   9. Lock-screen: short-poll (2s) for instant resume on unlock (no long sleep).
#  10. OOM self-protection: monitors gnome-shell RSS;
#      throttles or pauses wallpaper switching when memory is low.
#
# Requirements: gsettings, find, readlink, flock, python3 (stdlib sqlite3)
# Designed for GNOME desktop environment (Wayland & X11).
# 
# Date: 2024-06-27 / Refactored: 2026-03-28
# Author: Rackell
#*********************************************************************************************************

set -o pipefail

# ========== Configuration ==========
INTERVAL=${INTERVAL:-1}                       # minutes between wallpaper changes
FOLDER="${FOLDER:-/home/${USER}/myWallPaper/}" # primary image folder (trailing slash)
FOLDER="${FOLDER%/}/"                          # ensure trailing slash

FALLBACK_DIRS=(/usr/share/backgrounds /usr/share/pixmaps)

MAX_SHOW=${MAX_SHOW:-3}                        # display count before recycle/delete
RECYCLE_MODE=${RECYCLE_MODE:-true}              # true=recycle, false=delete
RECYCLE_DIR="${FOLDER}.recycle"

POST_DELETE_SLEEP=${POST_DELETE_SLEEP:-1}       # seconds after recycle/delete

# Lock-screen pause
PAUSE_WHEN_LOCKED="${PAUSE_WHEN_LOCKED:-true}"
# Short-poll interval (seconds) when screen is locked.
# The script checks lock status every LOCK_POLL_INTERVAL seconds,
# so unlock → resume latency is at most this value (not minutes).
LOCK_POLL_INTERVAL=${LOCK_POLL_INTERVAL:-2}

# Playlist / index management (SQLite backend via playlist_index.py)
# PLAYLIST_INDEX_PY: path to playlist_index.py (default: same dir as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYLIST_INDEX_PY="${PLAYLIST_INDEX_PY:-${SCRIPT_DIR}/playlist_index.py}"
# Path to the persistent SQLite DB (co-located with the script for easy portability).
# Override by exporting PLAYLIST_INDEX_DB before starting the script.
PLAYLIST_INDEX_DB="${PLAYLIST_INDEX_DB:-${SCRIPT_DIR}/index.db}"
export PLAYLIST_INDEX_DB
# Interval (seconds) between incremental index re-scans (default: 3h)
PLAYLIST_REBUILD_INTERVAL=${PLAYLIST_REBUILD_INTERVAL:-10800}
PLAYLIST_LAST_REBUILD=0

# Find options
FOLLOW_SYMLINKS=${FOLLOW_SYMLINKS:-true}
FIND_MAX_DEPTH=${FIND_MAX_DEPTH:-20}            # prevent symlink loop infinite recursion

# Fallback switching
FALLBACK_SWITCH_COOLDOWN=${FALLBACK_SWITCH_COOLDOWN:-60}
LAST_FALLBACK_SWITCH=0

# Empty-list adaptive backoff
EMPTY_BACKOFF_INITIAL=${EMPTY_BACKOFF_INITIAL:-5}
EMPTY_BACKOFF_MAX=${EMPTY_BACKOFF_MAX:-60}
EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_INITIAL

# inotify (optional)
USE_INOTIFY=0
if command -v inotifywait >/dev/null 2>&1 && [ "${WS_DISABLE_INOTIFY:-0}" != 1 ]; then
    USE_INOTIFY=1
fi

# Error tracking
ERRORCOUNT=0
ERROR_THRESHOLD=${ERROR_THRESHOLD:-20}          # cumulative errors × INTERVAL before exit

# Concurrency lock
GLOBAL_LOCK_FILE="${HOME}/myShell/.wallpaper_shuffle_v2.lock"

# Config file for HUP reload
CONFIG_FILE="${HOME}/myShell/.wallpaper_shuffle_v2.conf"

# Logging
LOG_LEVEL=${LOG_LEVEL:-info}                    # debug|info|warn|error

# ========== OOM Protection ==========
# Monitor gnome-shell RSS to detect memory leaks caused by frequent wallpaper changes.
# (GNOME 46 + X11 + NVIDIA has known GdkPixbuf/mutter leak on rapid wallpaper switching.)
# MemAvailable checks are omitted: on 32GB systems they would almost never trigger
# and add unnecessary subprocess overhead. Effective mitigation is simply INTERVAL>=5.
#
# Maximum RSS (KB) for gnome-shell before throttling wallpaper switches.
# Default: 4 GB. gnome-shell normally uses 300-800 MB.
# Recommended: 4194304 (32GB), 3145728 (16GB), 2097152 (8GB)
OOM_GNOME_RSS_MAX_KB=${OOM_GNOME_RSS_MAX_KB:-4194304}
# Seconds to pause when gnome-shell RSS is too high.
OOM_PAUSE_SECONDS=${OOM_PAUSE_SECONDS:-60}
# Track whether we are in throttle mode
OOM_THROTTLE_ACTIVE=0
# Original interval (to restore after throttle)
INTERVAL_ORIGINAL=$INTERVAL

# ========== Logging ==========
log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%F %T')"
    case "$LOG_LEVEL" in
        debug) ;;
        info)  [[ "$level" == "debug" ]] && return ;;
        warn)  [[ "$level" =~ ^(debug|info)$ ]] && return ;;
        error) [[ "$level" != "error" ]] && return ;;
    esac
    echo "[$level] $ts - $*" >&2
}

# ========== Sanity Checks ==========
if ! command -v gsettings >/dev/null 2>&1; then
    echo "gsettings not found. This script requires GNOME settings." >&2
    exit 1
fi

for cmd in find readlink flock python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        exit 1
    fi
done

# Verify playlist_index.py is accessible
if [ ! -f "$PLAYLIST_INDEX_PY" ]; then
    echo "playlist_index.py not found at: $PLAYLIST_INDEX_PY" >&2
    echo "Set PLAYLIST_INDEX_PY to its full path and retry." >&2
    exit 1
fi

# ========== GNOME Setup (once) ==========
SUPPORTS_DARK=0
if gsettings writable org.gnome.desktop.background picture-uri-dark >/dev/null 2>&1; then
    SUPPORTS_DARK=1
fi
gsettings set org.gnome.desktop.background picture-options "scaled" >/dev/null 2>&1 || true

# ========== Image Detection ==========
_find_cmd() {
    local d="$1"; shift
    local extra_args=("$@")
    local follow_flag=""
    [ "$FOLLOW_SYMLINKS" = true ] && follow_flag="-L"

    find $follow_flag "$d" -maxdepth "$FIND_MAX_DEPTH" \
        -path "${RECYCLE_DIR}" -prune -o \
        "${extra_args[@]}" \
        -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.gif' -o -iname '*.tga' -o -iname '*.webp' -o -iname '*.bmp' \) \
        -print
}

has_images() {
    local d="$1"
    [ -d "$d" ] || return 1
    # falsely indicating no images exist.
    { _find_cmd "$d" || true; } | head -1 | grep -q .
}

pick_fallback_dir() {
    local d
    for d in "${FALLBACK_DIRS[@]}"; do
        if has_images "$d"; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# ========== SQLite Index Management ==========
# Thin shell wrappers around playlist_index.py.
# All persistent state lives in the SQLite DB ($PLAYLIST_INDEX_DB).

_py_index() {
    python3 "$PLAYLIST_INDEX_PY" --db "$PLAYLIST_INDEX_DB" "$@"
}

# Perform an incremental scan (insert new files, deactivate missing ones).
build_playlist() {
    local workdir="$1"
    log info "Index scan (incremental): $workdir"
    if _py_index scan "$workdir" \
            --max-depth "$FIND_MAX_DEPTH" \
            $([ "$FOLLOW_SYMLINKS" != true ] && echo '--no-follow-symlinks') 2>&1 | while IFS= read -r line; do log info "  $line"; done; then
        PLAYLIST_LAST_REBUILD=$(date +%s)
        return 0
    fi
    log warn "Index scan failed for $workdir"
    return 1
}

# Full rebuild: drop all rows for this folder and re-scan.
rebuild_playlist() {
    local workdir="$1"
    log info "Index rebuild (full): $workdir"
    _py_index rebuild "$workdir" \
        --max-depth "$FIND_MAX_DEPTH" \
        $([ "$FOLLOW_SYMLINKS" != true ] && echo '--no-follow-symlinks') 2>&1 | while IFS= read -r line; do log info "  $line"; done
    PLAYLIST_LAST_REBUILD=$(date +%s)
}

# Read next image path from the index. Returns 1 if nothing available.
next_from_playlist() {
    _py_index next --max-show "$MAX_SHOW" --folder "$CURRENT_DIR"
}

should_rebuild_playlist() {
    local now
    now=$(date +%s)
    # Rebuild if DB does not exist yet
    [ ! -f "$PLAYLIST_INDEX_DB" ] && return 0
    # Periodic incremental re-scan
    [ $(( now - PLAYLIST_LAST_REBUILD )) -ge $PLAYLIST_REBUILD_INTERVAL ] && return 0
    return 1
}

# ========== Screen Lock Detection ==========
is_screen_locked() {
    [ "${PAUSE_WHEN_LOCKED}" = true ] || return 1

    if command -v gdbus >/dev/null 2>&1; then
        if gdbus call --session \
            --dest org.gnome.ScreenSaver \
            --object-path /org/gnome/ScreenSaver \
            --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q 'true'; then
            return 0
        fi
        if gdbus call --session \
            --dest org.freedesktop.ScreenSaver \
            --object-path /org/freedesktop/ScreenSaver \
            --method org.freedesktop.ScreenSaver.GetActive 2>/dev/null | grep -q 'true'; then
            return 0
        fi
    fi

    if command -v loginctl >/dev/null 2>&1; then
        local session_id
        session_id="${XDG_SESSION_ID:-$(loginctl 2>/dev/null | awk '/(seat0|tty)/ {print $1; exit}')}"
        if [ -n "$session_id" ]; then
            if loginctl show-session "$session_id" -p Locked 2>/dev/null | grep -q '=yes'; then
                return 0
            fi
        fi
    fi

    return 1
}

# Block while screen is locked, polling every LOCK_POLL_INTERVAL seconds.
# Returns immediately when screen is unlocked (worst-case latency = LOCK_POLL_INTERVAL).
wait_while_locked() {
    is_screen_locked || return 0
    log info "Screen locked, polling every ${LOCK_POLL_INTERVAL}s for unlock…"
    while is_screen_locked; do
        sleep "$LOCK_POLL_INTERVAL"
    done
    log info "Screen unlocked, resuming."
}

# ========== OOM Protection Helpers ==========
# Get gnome-shell RSS in KB. Returns 0 if gnome-shell not found.
get_gnome_shell_rss_kb() {
    local pid rss=0
    pid=$(pgrep -x gnome-shell 2>/dev/null | head -1)
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || echo 0)
    fi
    echo "$rss"
}

# Check gnome-shell memory health. Returns:
#   0 = OK, proceed normally
#   1 = HIGH RSS, should throttle (increase interval)
check_memory_health() {
    local gnome_rss
    gnome_rss=$(get_gnome_shell_rss_kb)

    if [ "$gnome_rss" -gt 0 ] && [ "$gnome_rss" -gt "$OOM_GNOME_RSS_MAX_KB" ]; then
        log warn "gnome-shell RSS high: ${gnome_rss}KB > ${OOM_GNOME_RSS_MAX_KB}KB"
        return 1
    fi

    return 0
}

# Apply OOM throttle: double the INTERVAL to reduce wallpaper change frequency.
oom_throttle_on() {
    if [ "$OOM_THROTTLE_ACTIVE" -eq 0 ]; then
        OOM_THROTTLE_ACTIVE=1
        INTERVAL_ORIGINAL=$INTERVAL
    fi
    local new_interval=$(( INTERVAL * 2 ))
    [ "$new_interval" -gt 30 ] && new_interval=30   # cap at 30 minutes
    if [ "$new_interval" -ne "$INTERVAL" ]; then
        INTERVAL=$new_interval
        log warn "OOM throttle: INTERVAL increased to ${INTERVAL}m (was ${INTERVAL_ORIGINAL}m)"
    fi
}

# Release OOM throttle: restore original INTERVAL.
oom_throttle_off() {
    if [ "$OOM_THROTTLE_ACTIVE" -eq 1 ]; then
        INTERVAL=$INTERVAL_ORIGINAL
        OOM_THROTTLE_ACTIVE=0
        log info "OOM throttle released: INTERVAL restored to ${INTERVAL}m"
    fi
}

# ========== Wait for New Files ==========
wait_for_new_files() {
    local dir="$1"
    local timeout=$EMPTY_BACKOFF_CURRENT

    if [ $USE_INOTIFY -eq 1 ]; then
        inotifywait -q -r -e create,close_write,move --timeout "$timeout" "$dir" >/dev/null 2>&1 || true
    else
        sleep "$timeout"
    fi

    # Exponential backoff progression (capped)
    if [ $EMPTY_BACKOFF_CURRENT -lt $EMPTY_BACKOFF_MAX ]; then
        EMPTY_BACKOFF_CURRENT=$(( EMPTY_BACKOFF_CURRENT * 2 ))
        [ $EMPTY_BACKOFF_CURRENT -gt $EMPTY_BACKOFF_MAX ] && EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_MAX
    fi
}

# ========== Recycle / Delete ==========
recycle_or_delete() {
    local filepath="$1"
    [ -e "$filepath" ] || return 0

    if [ "$RECYCLE_MODE" = true ]; then
        local rel_path="${filepath#$FOLDER}"
        local dest_dir="${RECYCLE_DIR}/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        local dest_file="${RECYCLE_DIR}/$rel_path"
        if [ -e "$dest_file" ]; then
            local base ext stem
            base="$(basename "$rel_path")"
            ext="${base##*.}"
            stem="${base%.*}"
            dest_file="${dest_dir}/${stem}_$(date +%s).${ext}"
        fi
        mv "$filepath" "$dest_file" 2>/dev/null || rm -f "$filepath"
        log info "recycled: $filepath → $dest_file"
    else
        rm -f "$filepath"
        log info "deleted: $filepath"
    fi

    # Clean empty directories (not recycle dir itself)
    find "$FOLDER" -maxdepth "$FIND_MAX_DEPTH" -type d -empty \
        -not -path "$RECYCLE_DIR" -not -path "$RECYCLE_DIR/*" \
        -delete 2>/dev/null || true

    [ "${POST_DELETE_SLEEP:-0}" -gt 0 ] && sleep "$POST_DELETE_SLEEP"
}

# ========== Signal Handlers ==========
REBUILD_REQUESTED=0
reload_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log info "Reloading config from $CONFIG_FILE"
        # Only source known variables (security: don't eval arbitrary code)
        while IFS='=' read -r key val; do
            key="${key// /}"
            val="${val// /}"
            case "$key" in
                INTERVAL|MAX_SHOW|RECYCLE_MODE|POST_DELETE_SLEEP|PAUSE_WHEN_LOCKED|\
                FOLLOW_SYMLINKS|FIND_MAX_DEPTH|PLAYLIST_REBUILD_INTERVAL|\
                EMPTY_BACKOFF_INITIAL|EMPTY_BACKOFF_MAX|LOG_LEVEL|ERROR_THRESHOLD|\
                OOM_GNOME_RSS_MAX_KB|OOM_PAUSE_SECONDS|\
                LOCK_POLL_INTERVAL|PLAYLIST_INDEX_DB|PLAYLIST_INDEX_PY)
                    declare -g "$key=$val"
                    log info "  $key=$val"
                    ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

request_rebuild() {
    REBUILD_REQUESTED=1
    log info "Playlist rebuild requested (USR1)"
}

cleanup_and_exit() {
    # SQLite DB is persistent — do not delete it on exit.
    log info "Wallpaper shuffle script v2 exited."
    exit 0
}

trap cleanup_and_exit EXIT TERM INT
trap request_rebuild USR1
trap reload_config HUP

# ========== Startup ==========
sleep 4    # wait for desktop environment

# Load config file at startup (same logic as HUP reload),
# so persistent settings take effect without needing an explicit HUP signal.
reload_config

# Ensure index DB directory exists
mkdir -p "$(dirname "$PLAYLIST_INDEX_DB")"

# Concurrency lock
mkdir -p "$(dirname "$GLOBAL_LOCK_FILE")"
exec 200>"$GLOBAL_LOCK_FILE" || { echo "Cannot open lock file" >&2; exit 1; }
if ! flock -n 200; then
    echo "Another instance running (lock: $GLOBAL_LOCK_FILE). Exiting." >&2
    exit 0
fi

# Decide initial working directory
ALLOW_DELETE=true
CURRENT_DIR="$FOLDER"

if [ -d "$FOLDER" ]; then
    if ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            log info "No images in $FOLDER, falling back to: $fb (no deletion)"
            CURRENT_DIR="$fb"
            ALLOW_DELETE=false
        else
            log warn "No images found anywhere."
            exit 0
        fi
    fi
else
    fb="$(pick_fallback_dir || true)"
    if [ -n "$fb" ]; then
        log info "Cannot access $FOLDER, using: $fb (no deletion)"
        CURRENT_DIR="$fb"
        ALLOW_DELETE=false
    else
        log error "Cannot access $FOLDER and no fallbacks available."
        exit 1
    fi
fi

# Optional initial wait
if [[ "${*}" == *wait* ]]; then
    sleep "${INTERVAL}m"
fi

# Ensure recycle dir exists if needed
[ "$RECYCLE_MODE" = true ] && mkdir -p "$RECYCLE_DIR"

# Build initial index (incremental scan; full rebuild if DB absent)
if [ ! -f "$PLAYLIST_INDEX_DB" ]; then
    rebuild_playlist "$CURRENT_DIR"
else
    build_playlist "$CURRENT_DIR"
fi

# ========== Main Loop ==========
while true; do

    # --- Directory recovery/switch ---
    if [ "$ALLOW_DELETE" = false ] && has_images "$FOLDER"; then
        log info "Primary folder has images again, switching back to $FOLDER"
        CURRENT_DIR="$FOLDER"
        ALLOW_DELETE=true
        build_playlist "$CURRENT_DIR"
    fi
    if [ "$ALLOW_DELETE" = true ] && ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            now_ts=$(date +%s)
            if [ $(( now_ts - LAST_FALLBACK_SWITCH )) -ge $FALLBACK_SWITCH_COOLDOWN ]; then
                log info "Primary empty, switching to: $fb"
                CURRENT_DIR="$fb"
                ALLOW_DELETE=false
                LAST_FALLBACK_SWITCH=$now_ts
                build_playlist "$CURRENT_DIR"
            fi
        fi
    fi

    # --- USR1 rebuild request (full rebuild) ---
    if [ "$REBUILD_REQUESTED" -eq 1 ]; then
        REBUILD_REQUESTED=0
        rebuild_playlist "$CURRENT_DIR"
    fi

    # --- Screen lock pause (instant resume on unlock) ---
    wait_while_locked

    # --- OOM protection (gnome-shell RSS leak detection) ---
    if ! check_memory_health; then
        oom_throttle_on
        log warn "OOM pause: sleeping ${OOM_PAUSE_SECONDS}s (gnome-shell RSS high)"
        sleep "$OOM_PAUSE_SECONDS"
        continue
    else
        oom_throttle_off
    fi

    # --- Scheduled incremental index re-scan ---
    if should_rebuild_playlist; then
        build_playlist "$CURRENT_DIR"
    fi

    # --- Pick next image from SQLite index ---
    # next_from_playlist calls `playlist_index.py next` which:
    #   • Picks a weighted-random active image with count < MAX_SHOW
    #   • Atomically increments its count in the DB
    #   • Auto-resets all counts if the round is exhausted
    #   • Outputs path on line 1, new count on line 2
    photo=""
    local_newcount=0
    {
        IFS= read -r photo
        IFS= read -r local_newcount
    } < <(next_from_playlist) || true

    if [ -z "$photo" ]; then
        # Index empty — try a fresh incremental scan first
        build_playlist "$CURRENT_DIR"
        {
            IFS= read -r photo
            IFS= read -r local_newcount
        } < <(next_from_playlist) || true
        if [ -z "$photo" ]; then
            wait_for_new_files "$CURRENT_DIR"
            continue
        fi
    fi

    # Resolve to absolute path (handles any remaining symlinks)
    photo=$(readlink -f "$photo" 2>/dev/null) || true
    if [ -z "$photo" ] || [ ! -f "$photo" ]; then
        log debug "Skipping missing: $photo"
        # Deactivate in DB so it won't be picked again (guard: only if non-empty)
        [ -n "$photo" ] && _py_index mark-inactive "$photo" 2>/dev/null || true
        continue
    fi

    # --- Schedule deferred recycle/delete if count has reached MAX_SHOW ---
    # Count is managed entirely by the SQLite DB (authoritative, persistent).
    # No file renaming needed; filenames remain unchanged throughout.
    DO_DELETE_AFTER_SLEEP=0
    DELETE_TARGET=""
    if [ "$ALLOW_DELETE" = true ] && [[ "$photo" == "$FOLDER"* ]]; then
        if [ "${local_newcount:-0}" -ge "$MAX_SHOW" ]; then
            DO_DELETE_AFTER_SLEEP=1
            DELETE_TARGET="$photo"
            log info "will recycle after display: $photo (count=$local_newcount)"
        fi
    fi

    # --- Set wallpaper ---
    if gsettings set org.gnome.desktop.background picture-uri "file://$photo" 2>/dev/null; then
        ERRORCOUNT=0

        if [ "$SUPPORTS_DARK" -eq 1 ]; then
            gsettings set org.gnome.desktop.background picture-uri-dark "file://$photo" 2>/dev/null || true
        fi

        # Reset empty backoff on success
        [ $EMPTY_BACKOFF_CURRENT -ne $EMPTY_BACKOFF_INITIAL ] && EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_INITIAL

        if [ "$ALLOW_DELETE" = true ]; then
            log info "wallpaper: $photo (count=$local_newcount, mode=primary)"
        else
            log info "wallpaper: $photo (mode=fallback)"
        fi
    else
        ((ERRORCOUNT++)) || true
        log warn "gsettings failed for: $photo (errors=$ERRORCOUNT)"
        if [ $((ERRORCOUNT * INTERVAL)) -gt "$ERROR_THRESHOLD" ]; then
            log error "Too many consecutive errors, exiting."
            cleanup_and_exit
        fi
    fi

    # --- Display interval ---
    sleep "${INTERVAL}m"

    # --- Deferred recycle/delete ---
    if [ "$DO_DELETE_AFTER_SLEEP" -eq 1 ] && [ -n "$DELETE_TARGET" ]; then
        recycle_or_delete "$DELETE_TARGET"
        # Keep DB in sync: the file is now in .recycle (or deleted), mark inactive.
        _py_index mark-inactive "$DELETE_TARGET" 2>/dev/null || true
    fi
done
