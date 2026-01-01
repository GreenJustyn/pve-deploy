#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_autoupdate.sh
# Description: Automated Proxmox Host Update & Reboot
# -----------------------------------------------------------------------------

set -u # Undefined variables are errors
# Note: We do NOT use 'set -e' here because we want to capture errors 
# and log them before deciding to reboot or exit.

# --- Configuration ---
LOG_FILE="/var/log/proxmox_autoupdate.log"

# --- Logging Helper ---
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log "=== Starting Proxmox Auto-Update Routine ==="

# 1. Pre-Update Check
CURRENT_VER=$(pveversion)
log "PRE-CHECK: Current PVE Version: $CURRENT_VER"

# 2. Update Package Lists
log "ACTION: Running apt-get update..."
if apt-get update >> "$LOG_FILE" 2>&1; then
    log "SUCCESS: Package lists updated."
else
    log "ERROR: apt-get update failed. Aborting."
    exit 1
fi

# 3. Perform Full Upgrade (Auto-Approve)
# We use 'dist-upgrade' or 'full-upgrade' which is recommended for Proxmox kernel updates
log "ACTION: Running apt-get full-upgrade..."
if apt-get full-upgrade -y >> "$LOG_FILE" 2>&1; then
    log "SUCCESS: System upgraded successfully."
else
    log "ERROR: apt-get full-upgrade failed. Check logs for details."
    # We exit here to prevent rebooting a broken system
    exit 1
fi

# 4. Cleanup
log "ACTION: Cleaning up (autoremove/autoclean)..."
apt-get autoremove -y >> "$LOG_FILE" 2>&1
apt-get autoclean >> "$LOG_FILE" 2>&1

# 5. Final Status Check
NEW_VER=$(pveversion)
log "POST-CHECK: New PVE Version: $NEW_VER"

# 6. Verbose Restart
log "WARNING: System Restart Initiated."
log "System is going down for reboot in 10 seconds..."
sleep 10

# Final sync to ensure logs are written to disk
sync

# Reboot
/sbin/shutdown -r now "Proxmox Auto-Update Completed. Rebooting."
