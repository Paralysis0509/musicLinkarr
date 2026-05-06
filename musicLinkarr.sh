#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Log/Debug Functions
# -----------------------------------------------------------------------------
log() {
    echo "[INFO] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
LOG_FILE="/log/musicLinkarr_$(date +%Y%m%d).log"

# Set to false to actually execute file operations
if [ -z "$DEBUG" ]; then
    DEBUG=false
fi
# 1. Strictly enforce required environment variables
if [ -z "$DEST_BASE" ]; then
    error "DEST_BASE environment variable is not defined. Exiting."
    exit 1
fi

if [ -z "$SRC_BASE" ]; then
    error "SRC_BASE environment variable is not defined. Exiting."
    exit 1
fi

# 2. Handle Arguments (Path first, Category optional)
PASSED_PATH="$1"
CATEGORY="$2"
# Default to 'music' user forgot to set it in docker-compose
WATCHED_CATEGORY="${WATCHED_CATEGORY:-music}"

# If a category was explicitly passed, and it is NOT "music", exit silently.
if [[ -n "$CATEGORY" ]] && [[ "$CATEGORY" != "$WATCHED_CATEGORY" ]]; then
    log "Ignored: Category is '$CATEGORY' (Not $WATCHED_CATEGORY)."
    exit 0
fi

# Determine the source target (Fallback to SRC_BASE if no path was passed)
SRC="${PASSED_PATH:-$SRC_BASE}"
# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
sanitize() {
    local val="$1"

    # 1. Remove control characters (newlines, tabs, null bytes, etc.)
    val="${val//[[:cntrl:]]/}"

    # 2. Remove forbidden chars (Windows/Linux) AND all dots (.)
    val="${val//[:?<>\\*|\"\/]/}"

    # 3. Remove leading spaces AND leading hyphens (prevents command flag confusion)
    val="${val#"${val%%[![:space:]-]*}"}"

    # 4. Remove trailing spaces
    val="${val%"${val##*[![:space:].]}"}"

    # 5. Handle Windows/SMB reserved device names
    # ${val^^} converts the string to uppercase for a case-insensitive match (Bash 4.0+)
    local upper_val="${val^^}"
    case "$upper_val" in
        CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
            val="${val}_safe"
            ;;
    esac

    # 6. Fallback if the string becomes completely empty after sanitization
    if [[ -z "$val" ]]; then
        val="unnamed_folder"
    fi

    echo "$val"
}
# --- New Cover Art Functions ---

log_curl() {
    local url="$1"
    local output="$2"

    log "CURL → $url"
    local response http_code
    response=$(curl -L -s -D - -o "$output" -w "\nFINAL_HTTP_CODE:%{http_code}" "$url" 2>&1)
    http_code=$(echo "$response" | grep "FINAL_HTTP_CODE" | cut -d: -f2)

    echo "$response" | grep -i "^Location:" | while read -r line; do
        log "Redirect → ${line#Location: }"
    done

    log "CURL ← HTTP $http_code"

    if [[ "$http_code" =~ ^2 ]]; then
        return 0
    else
        rm -f "$output"
        return 1
    fi
}

extract_embedded_cover() {
    local audio="$1"
    local out="$2"

    # Fallback to metaflac
    if [[ -n "$(metaflac --list --block-type=PICTURE "$audio" 2>/dev/null)" ]]; then
        log "Extracting embedded cover using metaflac"
        metaflac --export-picture-to="$out" "$audio" 2>/dev/null || true
        return 0
    else
        return 1
    fi
}

fetch_cover_online() {
    local artist="$1"
    local album="$2"
    local out="$3"

    if [[ -z "$artist" || -z "$album" || "$artist" == "Unknown Artist" || "$album" == "Unknown Album" ]]; then
        error "Missing valid metadata, cannot fetch online"
        return 1
    fi

    local query
    query=$(printf '%s' "artist:\"$artist\" AND release:\"$album\"" | sed 's/ /%20/g')

    local mb_url="https://musicbrainz.org/ws/2/release/?query=$query&fmt=json"
    local json_tmp
    json_tmp=$(mktemp)

    if ! log_curl "$mb_url" "$json_tmp"; then
        error "MusicBrainz query failed"
        rm -f "$json_tmp"
        return 1
    fi

    local mbid
    mbid=$(jq -r '.releases[0].id // empty' "$json_tmp" 2>/dev/null)
    rm -f "$json_tmp"

    if [[ -z "$mbid" ]]; then
        error "No MBID found for $artist - $album"
        return 1
    fi

    local cover_url="https://coverartarchive.org/release/$mbid/front"
    if log_curl "$cover_url" "$out"; then
        log "Downloaded cover from CoverArtArchive"
        return 0
    else
        error "Cover download failed"
        return 1
    fi
}

process_cover() {
    local src_dir="$1"
    local target_dir="$2"
    local first_flac="$3"
    local artist="$4"
    local album="$5"
    
    log "DEBUG process_cover target_dir='$target_dir'"
    local cover_dest="$target_dir/cover.jpg"
    local tmp_raw="$target_dir/.cover_raw_tmp"

    if [ "$DEBUG" = true ]; then
        log "[DRY RUN] Would process cover art for: $artist - $album"
        return 0
    fi

    if [[ -f "$cover_dest" ]]; then
        log "Cover already exists in destination. Skipping."
        return 0
    fi

    local found_cover=false

    # 1. Check existing in source folder
    for name in cover folder; do
        for ext in jpg JPG jpeg JPEG png PNG; do
            if [[ -f "$src_dir/$name.$ext" ]]; then
                cp "$src_dir/$name.$ext" "$tmp_raw"
                log "Using existing cover from source: $name.$ext"
                found_cover=true
                break 2 # Break out of both the 'ext' and 'name' loops
            fi
        done
    done

    # 2. Extract embedded
    if [[ "$found_cover" == false ]]; then
        if extract_embedded_cover "$first_flac" "$tmp_raw"; then
            log "Extracted embedded cover from FLAC."
            found_cover=true
        fi
    fi

    # 3. Fetch online
    if [[ "$found_cover" == false ]]; then
        if fetch_cover_online "$artist" "$album" "$tmp_raw"; then
            found_cover=true
        fi
    fi

    # 4. Resize and Convert (if cover was found via any method)
    if [[ "$found_cover" == true && -f "$tmp_raw" ]]; then
        local width height
        read -r width height < <(magick identify -format "%w %h" "$tmp_raw" 2>/dev/null || echo "0 0")
        
        log "Raw cover size: ${width}x${height}"

        # Check if resize/conversion is needed (larger than 1000px OR not already a JPEG)
        local mime_type
        mime_type=$(file -b --mime-type "$tmp_raw")

        if [[ "$width" -gt 1000 || "$height" -gt 1000 || "$mime_type" != "image/jpeg" ]]; then
            log "Resizing/converting cover → max 1000x1000 JPG"
            
            if magick "$tmp_raw" -resize '1000x1000>' -quality 90 "$cover_dest"; then
                log "Cover successfully normalized to JPG"
            else
                error "Image conversion failed"
            fi
        else
            # File is already a valid size and format
            mv "$tmp_raw" "$cover_dest"
            log "Cover copied (no resize/conversion needed)"
        fi
        
        # Cleanup temp file
        rm -f "$tmp_raw"
    else
        error "No cover found or generated for $target_dir"
    fi
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
log "Starting music organization project..."
if [ "$DEBUG" = true ]; then
    log "!!! RUNNING IN DEBUG/DRY-RUN MODE. NO FILES WILL BE MODIFIED. !!!"
fi

# Ensure all required tools are installed
for cmd in metaflac curl jq magick file; do
    if ! command -v "$cmd" &> /dev/null; then
        error "'$cmd' could not be found. Please install it."
        exit 1
    fi
done

if [ "$DEBUG" = false ]; then
    mkdir -p "$DEST_BASE"
fi

# 1. Dynamically build the 'find' command arguments
FIND_ARGS=("$SRC" -type d)

if [ -z "$1" ]; then
    # No specific folder was passed. We are scanning the entire root directory.
    # Add constraints to ignore the root folder itself and only grab today's changes.
    log "Running in Bulk Mode: Scanning for folders modified today."
    FIND_ARGS+=(-mindepth 1 -mtime -2)
else
    # qBittorrent passed a specific folder!
    # We want to process this exact folder and its subfolders, regardless of date.
    log "Running in Targeted Mode: Processing specific folder -> $SRC"
fi

# Execute the dynamic find command
find "${FIND_ARGS[@]}" -print0 | while IFS= read -r -d '' DIR; do
    
    # 1. Recursively find FLAC files inside this directory
    flac_files=()
    while IFS= read -r -d '' file; do
        flac_files+=("$file")
    done < <(find "$DIR" -type f -name "*.flac" -print0)
    # Skip if no FLACs
    if [ ${#flac_files[@]} -eq 0 ]; then
        continue
    fi

    log "Found modified folder with FLACs: $DIR"

    # --- 2. Get Album and Artist from the FIRST flac file ---
    FIRST_FLAC="${flac_files[0]}"

    ARTIST_RAW="$(metaflac --show-tag=ALBUMARTIST "$FIRST_FLAC" | cut -d= -f2-)"
    if [ -z "$ARTIST_RAW" ]; then
        ARTIST_RAW="$(metaflac --show-tag=ARTIST "$FIRST_FLAC" | cut -d= -f2-)"
    fi
    ARTIST_RAW="${ARTIST_RAW:-Unknown Artist}"
    ALBUM_ARTIST="$(sanitize "$ARTIST_RAW")"

    ALBUM_RAW="$(metaflac --show-tag=ALBUM "$FIRST_FLAC" | cut -d= -f2-)"
    ALBUM_RAW="${ALBUM_RAW:-Unknown Album}"
    ALBUM_TITLE="$(sanitize "$ALBUM_RAW")"

    # --- 3. Create the target directories ---
    log "DEBUG Artist='$ALBUM_ARTIST' Album='$ALBUM_TITLE'"
    TARGET_DIR="$DEST_BASE/$ALBUM_ARTIST/$ALBUM_TITLE"
    
    if [ ! -d "$TARGET_DIR" ]; then
        if [ "$DEBUG" = true ]; then
            log "[DRY RUN] Would create album directory: $TARGET_DIR"
        else
            log "Creating album directory: $TARGET_DIR"
            mkdir -p "$TARGET_DIR" || { error "Failed to create directory: $TARGET_DIR"; continue; }
        fi
    fi

    # --- 4. Handle Cover Art ---
    # We pass the required data directly to our new unified cover function
    process_cover "$DIR" "$TARGET_DIR" "$FIRST_FLAC" "$ALBUM_ARTIST" "$ALBUM_TITLE"

    # --- 5. Process each FLAC file ---
    for flac in "${flac_files[@]}"; do
        
        # Title
        TITLE_RAW="$(metaflac --show-tag=TITLE "$flac" | cut -d= -f2-)"
        TITLE="$(sanitize "$TITLE_RAW")"
        TITLE="${TITLE:-Unknown_Title}"

        # Track Number
        TRACK_RAW="$(metaflac --show-tag=TRACKNUMBER "$flac" | cut -d= -f2-)"
        TRACK_NUM="${TRACK_RAW%%/*}"
        if [[ "$TRACK_NUM" =~ ^[0-9]+$ ]]; then
            TRACK_PADDED=$(printf "%02d" "$((10#$TRACK_NUM))")
        else
            TRACK_PADDED="00"
        fi

        # CD / Disc Number
        CD_RAW="$(metaflac --show-tag=DISCNUMBER "$flac" | cut -d= -f2-)"
        CD_NUM="${CD_RAW%%/*}"
        
        if [[ -n "$CD_NUM" ]] && [[ "$CD_NUM" =~ ^[0-9]+$ ]]; then
            CD_PADDED=$(printf "%02d" "$((10#$CD_NUM))")
            FINAL_FILENAME="${CD_PADDED}-${TRACK_PADDED} - ${TITLE}.flac"
        else
            FINAL_FILENAME="${TRACK_PADDED} - ${TITLE}.flac"
        fi

        DEST_FLAC="$TARGET_DIR/$FINAL_FILENAME"

        # Hardlink the file
        if [ ! -f "$DEST_FLAC" ]; then
            if [ "$DEBUG" = true ]; then
                log "[DRY RUN] Would hardlink: '$flac' -> '$DEST_FLAC'"
            else
                ln "$flac" "$DEST_FLAC"
                if [ $? -eq 0 ]; then
                    log "Hardlinked: $FINAL_FILENAME"
                else
                    error "Failed to hardlink: $flac -> $DEST_FLAC"
                fi
            fi
        else
            log "Already exists, skipping: $FINAL_FILENAME"
        fi

    done

done

log "Project execution completed."
