#!/bin/bash

#*********************************************************************************************************
# Photography wallpaper random switch script, a tool for photography enthusiasts to study excellent works.
# This script randomly selects an image from the specified folder as the desktop wallpaper,
# waits for a specified number of minutes after each switch,
# and deletes each image after it has been displayed 3 times.
# Recursively searches subfolders for images.
# Supported image formats: jpg, jpeg, png, gif, tga (case-insensitive).
# Requires: gsettings, find, shuf, awk, grep, readlink.
# Designed for GNOME desktop environment.
# Author: Rackell
# Date: 2024-06-27
#********************************************************************************************************


# Default interval time (minutes)
INTERVAL=1
# Primary image folder
FOLDER="/home/rackell/myWallPaper/"

# Fallback system folders (first one with images will be used)
FALLBACK_DIRS=(/usr/share/backgrounds /usr/share/pixmaps)
# Local count file (stores: "<full path> <count>"; path may contain spaces; count is last field)
COUNT_FILE="$HOME/myShell/.wallpaper_shuffle_count.txt"
LOCK_FILE="${COUNT_FILE}.lock"

# Configurable maximum successful displays before removal (A)
MAX_SHOW=3
# Recycle mode (C): if true, move file into hidden recycle folder under primary instead of permanent delete
RECYCLE_MODE=true
RECYCLE_DIR="${FOLDER%/}/.recycle"

# Sleep seconds after a file is removed/recycled (B). Set to 0 to disable.
POST_DELETE_SLEEP=1

# Exponential backoff settings for locked screen (in seconds)
LOCK_SLEEP_INITIAL=10      # initial wait
LOCK_SLEEP_MAX=600         # maximum wait (10 minutes)
LOCK_SLEEP_CURRENT=$LOCK_SLEEP_INITIAL

# Whether to pause switching while the screen is locked (env override supported)
PAUSE_WHEN_LOCKED="${PAUSE_WHEN_LOCKED:-true}"

# File list cache / refresh tuning (optimize for thousands of images)
REFRESH_SECONDS=10800        # Re-scan directory tree at most every 3 hours (unless list exhausted)
FILES=()                     # Cached shuffled list
FILE_LIST_LAST_REFRESH=0     # Epoch seconds of last refresh
NEXT_INDEX=0                 # Index into FILES

# Whether to follow symlinked directories (if your images reside only in symlinked subfolders set to true)
FOLLOW_SYMLINKS=true


# Minimum seconds between fallback switches to avoid oscillation
FALLBACK_SWITCH_COOLDOWN=60
LAST_FALLBACK_SWITCH=0

# Adaptive backoff for empty playable list (seconds)
EMPTY_BACKOFF_INITIAL=5
EMPTY_BACKOFF_MAX=60
EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_INITIAL

# Enable inotify auto if available (can force off by exporting WS_DISABLE_INOTIFY=1 before run)
USE_INOTIFY=0
if command -v inotifywait >/dev/null 2>&1 && [ "${WS_DISABLE_INOTIFY:-0}" != 1 ]; then
    USE_INOTIFY=1
fi

wait_for_new_files() {
    local dir="$1"; local reason="$2"; local timeout=$EMPTY_BACKOFF_CURRENT
    # Try inotify for responsive wake-up
    if [ $USE_INOTIFY -eq 1 ]; then
        inotifywait -q -r -e create,close_write,move --timeout $timeout "$dir" >/dev/null 2>&1 || true
    else
        sleep $timeout
    fi
    # Exponential backoff progression (capped)
    if [ $EMPTY_BACKOFF_CURRENT -lt $EMPTY_BACKOFF_MAX ]; then
        EMPTY_BACKOFF_CURRENT=$(( EMPTY_BACKOFF_CURRENT * 2 ))
        [ $EMPTY_BACKOFF_CURRENT -gt $EMPTY_BACKOFF_MAX ] && EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_MAX
    fi
}

# Sanity checks
if ! command -v gsettings >/dev/null 2>&1; then
    echo "gsettings not found. This script requires GNOME settings (org.gnome.desktop.background)." >&2
    exit 1
fi

# Detect optional dark variant support & set picture-options once to reduce repeated DBus calls
SUPPORTS_DARK=0
if gsettings writable org.gnome.desktop.background picture-uri-dark >/dev/null 2>&1; then
    SUPPORTS_DARK=1
fi
gsettings set org.gnome.desktop.background picture-options "scaled" >/dev/null 2>&1 || true

has_images() {
    local d="$1"
    [ -d "$d" ] || return 1
    if [ "$FOLLOW_SYMLINKS" = true ]; then
        # Exclude recycle dir so that only files in .recycle are NOT treated as active images
        if [ -n "$RECYCLE_DIR" ] && [[ "$RECYCLE_DIR" == "$d"* ]]; then
            find -L "$d" -path "$RECYCLE_DIR" -prune -o -type f \
                \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print -quit | grep -q .
        else
            find -L "$d" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print -quit | grep -q .
        fi
    else
        if [ -n "$RECYCLE_DIR" ] && [[ "$RECYCLE_DIR" == "$d"* ]]; then
            find "$d" -path "$RECYCLE_DIR" -prune -o -type f \
                \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print -quit | grep -q .
        else
            find "$d" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print -quit | grep -q .
        fi
    fi
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

# Wait 4 seconds before starting to ensure the desktop environment is loaded
sleep 4
# Decide initial working directory and deletion policy
ALLOW_DELETE=true
if cd "$FOLDER" 2>/dev/null; then
    if ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            echo "No images in $FOLDER, falling back to system: $fb (no deletion)"
            cd "$fb" || { echo "Cannot enter $fb"; exit 1; }
            ALLOW_DELETE=false
        else
            echo "No photo files found in $FOLDER and no system backgrounds available."
            exit 0
        fi
    fi
else
    fb="$(pick_fallback_dir || true)"
    if [ -n "$fb" ]; then
        echo "Cannot enter $FOLDER, using system: $fb (no deletion)"
        cd "$fb" || { echo "Cannot enter $fb"; exit 1; }
        ALLOW_DELETE=false
    else
        echo "Cannot enter $FOLDER and no system backgrounds available."
        exit 1
    fi
fi

if [[ $@ == *wait* ]]; then  
    sleep "${INTERVAL}m"
fi


mkdir -p "$(dirname "$COUNT_FILE")"
touch "$COUNT_FILE"
# Acquire exclusive lock for the whole runtime to avoid concurrent corruption
exec 200>"$LOCK_FILE" || { echo "Cannot open lock file $LOCK_FILE" >&2; exit 1; }
if ! flock -n 200; then
    echo "Another instance is running (lock: $LOCK_FILE). Exiting." >&2
    exit 0
fi

cleanup_and_exit() {
    [ -f "$COUNT_FILE.tmp" ] && rm -f "$COUNT_FILE.tmp"
    # Release lock (fd 200 will close on exit). Optionally remove lock file.
    # rm -f "$LOCK_FILE"  # uncomment if you prefer deleting the lock file each run
    echo "Wallpaper shuffle script exited."
    exit 0
}
trap cleanup_and_exit EXIT TERM

ERRORCOUNT=0

is_screen_locked() {
    # Return 0 (true) if the session is locked, else 1 (false)
    # Multiple strategies: GNOME ScreenSaver DBus -> freedesktop ScreenSaver -> loginctl
    [ "${PAUSE_WHEN_LOCKED:-true}" = true ] || return 1

    # Prefer gdbus queries (fast and reliable on GNOME)
    if command -v gdbus >/dev/null 2>&1; then
        # org.gnome.ScreenSaver
        if gdbus call --session \
            --dest org.gnome.ScreenSaver \
            --object-path /org/gnome/ScreenSaver \
            --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q 'true'; then
            return 0
        fi
        # org.freedesktop.ScreenSaver
        if gdbus call --session \
            --dest org.freedesktop.ScreenSaver \
            --object-path /org/freedesktop/ScreenSaver \
            --method org.freedesktop.ScreenSaver.GetActive 2>/dev/null | grep -q 'true'; then
            return 0
        fi
    fi

    # Fallback to loginctl Locked property
    if command -v loginctl >/dev/null 2>&1; then
        # Prefer current session id if available, else try common active entries
        session_id="${XDG_SESSION_ID:-$(loginctl | awk '/(seat0|tty)/ {print $1; exit}') }"
        if [ -n "$session_id" ]; then
            if loginctl show-session "$session_id" -p Locked 2>/dev/null | grep -q '=yes'; then
                return 0
            fi
        fi
    fi

    return 1
}

# --- Count helper functions supporting paths with spaces ---
get_photo_count() {
    local photo="$1"
    awk -v f="$photo" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p==f){print c; exit}
        }
    ' "$COUNT_FILE"
}

update_photo_count() {
    local photo="$1" newcount="$2"
    awk -v f="$photo" -v nc="$newcount" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p!=f) print p" "c;
        }
        END { print f" "nc }
    ' "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
}

remove_photo_entry() {
    local photo="$1"
    awk -v f="$photo" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p!=f) print p" "c;
        }
    ' "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
}

refresh_file_list() {
    FILE_LIST_LAST_REFRESH=$(date +%s)
    # Build list excluding recycle dir, then shuffle once
    if [ "$FOLLOW_SYMLINKS" = true ]; then
        mapfile -t FILES < <(find -L . -path './.recycle' -prune -o -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print | shuf)
    else
        mapfile -t FILES < <(find . -path './.recycle' -prune -o -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print | shuf)
    fi
    NEXT_INDEX=0
}

should_refresh_list() {
    local now=$(date +%s)
    if [ ${#FILES[@]} -eq 0 ]; then return 0; fi
    if [ $(( now - FILE_LIST_LAST_REFRESH )) -ge $REFRESH_SECONDS ]; then return 0; fi
    return 1
}

while true; do
    # Fallback recovery or switch logic
    if [ "$ALLOW_DELETE" = false ] && has_images "$FOLDER"; then
        echo "Primary folder now has images, switching back to $FOLDER"
        cd "$FOLDER" || true
        ALLOW_DELETE=true
        FILES=() # force refresh
    fi
    if [ "$ALLOW_DELETE" = true ] && ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            echo "Primary folder empty, switching to system: $fb (no deletion)"
            cd "$fb" || true
            ALLOW_DELETE=false
            FILES=() # force refresh
        fi
    fi

    # If screen locked, optionally pause switching with exponential backoff
    if is_screen_locked; then
        echo "[info] $(date '+%F %T') - Screen locked, waiting ${LOCK_SLEEP_CURRENT}s (exp backoff)."
        sleep "$LOCK_SLEEP_CURRENT"
        if [ "$LOCK_SLEEP_CURRENT" -lt "$LOCK_SLEEP_MAX" ]; then
            LOCK_SLEEP_CURRENT=$(( LOCK_SLEEP_CURRENT * 2 ))
            [ "$LOCK_SLEEP_CURRENT" -gt "$LOCK_SLEEP_MAX" ] && LOCK_SLEEP_CURRENT=$LOCK_SLEEP_MAX
        fi
        continue
    else
        [ "$LOCK_SLEEP_CURRENT" -ne "$LOCK_SLEEP_INITIAL" ] && LOCK_SLEEP_CURRENT=$LOCK_SLEEP_INITIAL
    fi

    # Refresh file list if needed
    if ! should_refresh_list; then
        refresh_file_list
    fi

    if [ ${#FILES[@]} -eq 0 ]; then
        # Revalidate whether primary folder truly has active images (excluding recycle)
        if [ "$ALLOW_DELETE" = true ]; then
            if has_images "$FOLDER"; then
                # debug removed
                refresh_file_list
                if [ ${#FILES[@]} -eq 0 ]; then
                    # Still empty though has_images reported true: wait adaptively for filesystem changes
                    wait_for_new_files "$FOLDER" "primary-empty-after-refresh"
                    continue
                fi
            else
                now_ts=$(date +%s)
                if [ $(( now_ts - LAST_FALLBACK_SWITCH )) -lt $FALLBACK_SWITCH_COOLDOWN ]; then
                    # Cooldown active; wait adaptively instead of immediate retry
                    wait_for_new_files "$FOLDER" "cooldown-primary-empty"
                    continue
                fi
                fb="$(pick_fallback_dir || true)"
                if [ -n "$fb" ]; then
                    echo "Trying fallback: $fb (no deletion)"
                    cd "$fb" || true
                    ALLOW_DELETE=false
                    FILES=()
                    LAST_FALLBACK_SWITCH=$now_ts
                    continue
                fi
                wait_for_new_files "$FOLDER" "primary-empty-no-fallback"
                continue
            fi
        else
            # In fallback already and list empty; attempt refresh first
            refresh_file_list
            if [ ${#FILES[@]} -eq 0 ]; then
                wait_for_new_files "$(pwd)" "fallback-empty"
                continue
            fi
        fi
    fi

    # Pull next photo from cache
    photo="${FILES[$NEXT_INDEX]}"
    NEXT_INDEX=$(( NEXT_INDEX + 1 ))
    if [ $NEXT_INDEX -ge ${#FILES[@]} ]; then
        # Force refresh next iteration
        FILES=()
    fi

    DO_DELETE_AFTER_SLEEP=0
    DELETE_TARGET=""
    photo=$(readlink -f "$photo")  
    [ -z "$photo" ] && continue
    count=$(get_photo_count "$photo")
    [ -z "$count" ] && count=0

        # Try to set wallpaper. Only on SUCCESS do we increment display count.
        if gsettings set org.gnome.desktop.background picture-uri "file://$photo"; then
            ERRORCOUNT=0
            # Optional: set dark variant if supported (ignore errors)
            if [ "$SUPPORTS_DARK" -eq 1 ]; then
                gsettings set org.gnome.desktop.background picture-uri-dark "file://$photo" || true
            fi
            newcount=$((count+1))
            update_photo_count "$photo" "$newcount"
            echo "[info] $(date '+%F %T') - set wallpaper: $photo (count=$newcount mode=$([ "$ALLOW_DELETE" = true ] && echo primary || echo fallback))"
            # Reset empty-list adaptive backoff on successful progress
            [ $EMPTY_BACKOFF_CURRENT -ne $EMPTY_BACKOFF_INITIAL ] && EMPTY_BACKOFF_CURRENT=$EMPTY_BACKOFF_INITIAL
            # Mark for removal/recycle AFTER the display interval (defer actual deletion)
            if [ "$newcount" -ge "$MAX_SHOW" ] && [ "$ALLOW_DELETE" = true ] && [[ "$photo" == "$FOLDER"* ]]; then
                DO_DELETE_AFTER_SLEEP=1
                DELETE_TARGET="$photo"
                echo "[info] $(date '+%F %T') - will remove after display interval: $photo (count=$newcount)"
            fi
        else
            ((ERRORCOUNT++))
            echo "[warn] gsettings failed to set picture-uri for: $photo (no count increment)" >&2
            if [ $((ERRORCOUNT * INTERVAL)) -gt 20 ]; then
                cleanup_and_exit
            fi
        fi

        # Wait for the specified number of minutes before switching to the next image
    sleep "${INTERVAL}m"

        # Perform deferred delete/recycle if flagged
        if [ "$DO_DELETE_AFTER_SLEEP" -eq 1 ] && [ -n "$DELETE_TARGET" ]; then
            if [ -e "$DELETE_TARGET" ]; then
                if [ "$RECYCLE_MODE" = true ]; then
                    rel_path="${DELETE_TARGET#$FOLDER}"   # relative to primary
                    dest_dir="${RECYCLE_DIR}/$(dirname "$rel_path")"
                    mkdir -p "$dest_dir"
                    dest_file="${RECYCLE_DIR}/$rel_path"
                    if [ -e "$dest_file" ]; then
                        base="$(basename "$rel_path")"
                        dest_file="${dest_dir}/${base%.*}_$(date +%s).${base##*.}"
                    fi
                    mv "$DELETE_TARGET" "$dest_file" 2>/dev/null || rm -f "$DELETE_TARGET"
                    echo "[info] $(date '+%F %T') - recycled(after display): $DELETE_TARGET -> $dest_file" 
                else
                    rm -f "$DELETE_TARGET"
                    echo "[info] $(date '+%F %T') - deleted(after display): $DELETE_TARGET" 
                fi
            fi
            remove_photo_entry "$DELETE_TARGET"
            find "$FOLDER" -type d -empty -not -path "$RECYCLE_DIR" -delete
            if [ "${POST_DELETE_SLEEP:-0}" -gt 0 ]; then
                sleep "$POST_DELETE_SLEEP"
            fi
        fi
done