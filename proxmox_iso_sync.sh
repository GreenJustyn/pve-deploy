#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_iso_sync.sh
# Description: Dynamic ISO Scraper & Sync. Finds latest ISOs from provider pages.
# Schedule: Daily @ 02:00
# -----------------------------------------------------------------------------

set -u

# --- Configuration ---
STORAGE_ID="local"
LOG_FILE="/var/log/proxmox_iso_sync.log"
MANIFEST="/root/iac/iso-images.json"

# --- Logging Helper ---
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log "=== Starting Dynamic ISO Sync Routine ==="

# 1. Validation
if ! command -v jq &> /dev/null; then log "ERROR: jq missing."; exit 1; fi
if [ ! -f "$MANIFEST" ]; then log "ERROR: Manifest $MANIFEST missing."; exit 1; fi

# 2. Storage Path Detection
STORAGE_PATH=$(pvesm path "$STORAGE_ID:iso" 2>/dev/null | xargs dirname 2>/dev/null)
if [ -z "$STORAGE_PATH" ] || [ "$STORAGE_PATH" == "." ]; then
    STORAGE_PATH="/var/lib/vz/template/iso"
    log "WARN: pvesm failed. Defaulting to $STORAGE_PATH"
fi
if [ ! -d "$STORAGE_PATH" ]; then log "ERROR: Path $STORAGE_PATH not found."; exit 1; fi

log "INFO: Managing ISOs in $STORAGE_PATH"

# 3. Dynamic Discovery & Download
declare -a KEPT_FILES=()

# Read JSON array
COUNT=$(jq '. | length' "$MANIFEST")
for ((i=0; i<$COUNT; i++)); do
    OS=$(jq -r ".[$i].os" "$MANIFEST")
    PAGE=$(jq -r ".[$i].source_page" "$MANIFEST")
    PATTERN=$(jq -r ".[$i].pattern" "$MANIFEST")

    log "CHECKING: $OS (Pattern: $PATTERN)..."

    # Scrape the page for the file name
    # We look for href="PATTERN" or just the text matching PATTERN
    # sort -V sorts version numbers correctly (e.g. 22.04.2 vs 22.04.10)
    LATEST_FILE=$(curl -sL "$PAGE" | grep -oP "$PATTERN" | sort -V | tail -n 1)

    if [ -z "$LATEST_FILE" ]; then
        log "ERROR: Could not find any file matching '$PATTERN' on $PAGE"
        continue
    fi

    # Construct Full Download URL
    # If PAGE ends with /, append file. Otherwise add /.
    if [[ "$PAGE" == */ ]]; then
        DOWNLOAD_URL="${PAGE}${LATEST_FILE}"
    else
        DOWNLOAD_URL="${PAGE}/${LATEST_FILE}"
    fi

    TARGET_FILE="$STORAGE_PATH/$LATEST_FILE"
    KEPT_FILES+=("$LATEST_FILE")

    # Reconciliation Logic
    if [ -f "$TARGET_FILE" ]; then
        log "OK: $LATEST_FILE is current."
    else
        log "NEW VERSION FOUND: $LATEST_FILE"
        log "DOWNLOADING: $DOWNLOAD_URL"
        
        if wget -q --show-progress -O "${TARGET_FILE}.tmp" "$DOWNLOAD_URL"; then
            mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
            log "SUCCESS: Downloaded $LATEST_FILE"
        else
            log "ERROR: Download failed for $LATEST_FILE"
            rm -f "${TARGET_FILE}.tmp"
        fi
    fi
done

# 4. Cleanup (Foreign & Old Version Detection)
log "AUDIT: Checking for obsolete ISO files..."

# List all ISOs currently in storage
EXISTING_FILES=$(ls "$STORAGE_PATH"/*.iso 2>/dev/null | xargs -n 1 basename)

for file in $EXISTING_FILES; do
    is_kept=false
    for kept in "${KEPT_FILES[@]}"; do
        if [[ "$file" == "$kept" ]]; then
            is_kept=true
            break
        fi
    done

    if [ "$is_kept" == "false" ]; then
        # Check if this file "looks like" one of our managed OSs but is an old version
        # This is optional safety, but here we strictly delete anything not in KEPT_FILES
        log "DELETE: $file (Obsolete or Foreign). Removing..."
        rm -f "$STORAGE_PATH/$file"
        log "SUCCESS: Deleted $file"
    fi
done

log "=== ISO Sync Complete ==="