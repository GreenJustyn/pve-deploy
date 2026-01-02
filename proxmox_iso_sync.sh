#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_iso_sync.sh
# Description: ISO State Reconciliation. Downloads new ISOs, removes old/foreign ones.
# Schedule: Daily @ 02:00
# -----------------------------------------------------------------------------

set -u

# --- Configuration ---
# Target Storage ID in Proxmox (Default is usually 'local')
STORAGE_ID="local"
LOG_FILE="/var/log/proxmox_iso_sync.log"
MANIFEST="/root/iac/iso-images.json"

# --- Logging Helper ---
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log "=== Starting ISO Sync Routine ==="

# 1. Validate Environment
if ! command -v jq &> /dev/null; then
    log "ERROR: jq is missing. Please install it."
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    log "ERROR: Manifest file $MANIFEST not found."
    exit 1
fi

# 2. Get Local ISO Directory Path
# pvesm path returns something like "/var/lib/vz/template/iso/file.iso"
# We just want the directory.
STORAGE_PATH=$(pvesm path "$STORAGE_ID:iso" 2>/dev/null | xargs dirname 2>/dev/null)

# Fallback if pvesm fails (common on some setups)
if [ -z "$STORAGE_PATH" ] || [ "$STORAGE_PATH" == "." ]; then
    STORAGE_PATH="/var/lib/vz/template/iso"
    log "WARN: Could not detect path via pvesm. Defaulting to $STORAGE_PATH"
fi

if [ ! -d "$STORAGE_PATH" ]; then
    log "ERROR: Storage path $STORAGE_PATH does not exist."
    exit 1
fi

log "INFO: Managing ISOs in $STORAGE_PATH"

# 3. Build Expected File List from JSON
declare -a EXPECTED_ISOS=()
while IFS= read -r filename; do
    EXPECTED_ISOS+=("$filename")
done < <(jq -r '.[].filename' "$MANIFEST")

# 4. DOWNLOAD PHASE (Reconciliation)
# Loop through JSON definitions
for row in $(jq -r '.[] | @base64' "$MANIFEST"); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
    
    NAME=$(_jq '.filename')
    URL=$(_jq '.url')
    OS=$(_jq '.os')
    
    TARGET_FILE="$STORAGE_PATH/$NAME"

    if [ -f "$TARGET_FILE" ]; then
        # File exists - we assume it's good (Checking hash would be better, but slow)
        log "OK: $NAME ($OS) exists."
    else
        log "MISSING: $NAME ($OS). Downloading..."
        log "SOURCE: $URL"
        
        # Download with wget (using temp file to prevent partials)
        if wget -q --show-progress -O "${TARGET_FILE}.tmp" "$URL"; then
            mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
            log "SUCCESS: Downloaded $NAME"
        else
            log "ERROR: Failed to download $NAME"
            rm -f "${TARGET_FILE}.tmp"
        fi
    fi
done

# 5. CLEANUP PHASE (Foreign Object Detection)
# We list files in the directory and delete any NOT in our EXPECTED_ISOS array
log "AUDIT: Checking for obsolete or foreign ISO files..."

# Get list of .iso files in directory
EXISTING_FILES=$(ls "$STORAGE_PATH"/*.iso 2>/dev/null | xargs -n 1 basename)

for file in $EXISTING_FILES; do
    # Check if file is in EXPECTED_ISOS
    is_expected=false
    for expected in "${EXPECTED_ISOS[@]}"; do
        if [[ "$file" == "$expected" ]]; then
            is_expected=true
            break
        fi
    done

    if [ "$is_expected" == "false" ]; then
        log "DELETE: $file is not in the manifest (Obsolete/Foreign). Removing..."
        rm -f "$STORAGE_PATH/$file"
        log "SUCCESS: Deleted $file"
    fi
done

log "=== ISO Sync Complete ==="