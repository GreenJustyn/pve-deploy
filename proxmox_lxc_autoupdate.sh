#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_lxc_autoupdate.sh
# Description: Automated LXC Container Updater
#              Based on tteck's Proxmox Helper Scripts (Headless/Logging Adaptation)
# Schedule: Sundays at 01:00
# -----------------------------------------------------------------------------

set -u

# --- Configuration ---
LOG_FILE="/var/log/proxmox_lxc_autoupdate.log"

# --- Logging Helper ---
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log "=== Starting LXC Auto-Update Routine ==="

# Define the update function (Adapted from tteck)
update_container() {
    local container=$1
    local name=$(pct exec "$container" hostname)
    local os=$(pct config "$container" | awk '/^ostype/ {print $2}')

    log "ACTION: Updating Container $container ($name) [OS: $os]..."

    case "$os" in
        alpine)
            pct exec "$container" -- ash -c "apk -U upgrade" >> "$LOG_FILE" 2>&1
            ;;
        archlinux)
            pct exec "$container" -- bash -c "pacman -Syyu --noconfirm" >> "$LOG_FILE" 2>&1
            ;;
        fedora|rocky|centos|alma)
            pct exec "$container" -- bash -c "dnf -y update && dnf -y upgrade" >> "$LOG_FILE" 2>&1
            ;;
        ubuntu|debian|devuan)
            pct exec "$container" -- bash -c "apt-get update 2>/dev/null" >> "$LOG_FILE" 2>&1
            pct exec "$container" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade" >> "$LOG_FILE" 2>&1
            # Cleanup python externals managed if necessary (from original script)
            pct exec "$container" -- bash -c "rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED" 2>/dev/null
            ;;
        opensuse)
            pct exec "$container" -- bash -c "zypper ref && zypper --non-interactive dup" >> "$LOG_FILE" 2>&1
            ;;
        *)
            log "WARN: Unknown OS '$os' for container $container. Skipping."
            ;;
    esac
}

# --- Main Loop ---
containers_needing_reboot=()

# Get list of all container IDs (skip header)
for container in $(pct list | awk 'NR>1 {print $1}'); do
    
    status=$(pct status $container)
    template=$(pct config $container | grep -q "template:" && echo "true" || echo "false")

    # Skip Templates
    if [ "$template" == "true" ]; then
        log "INFO: Skipping Template $container"
        continue
    fi

    if [ "$status" == "status: stopped" ]; then
        log "INFO: Container $container is STOPPED. Temporarily starting for update..."
        pct start $container
        sleep 10 # Wait for network/init
        
        update_container $container
        
        log "INFO: Shutting down temporary container $container..."
        pct shutdown $container
        
    elif [ "$status" == "status: running" ]; then
        log "INFO: Container $container is RUNNING. Proceeding with live update..."
        update_container $container
    fi

    # Check for Reboot Requirement
    if pct exec "$container" -- [ -e "/var/run/reboot-required" ]; then
        local hostname=$(pct exec "$container" hostname)
        containers_needing_reboot+=("$container ($hostname)")
        log "NOTICE: Container $container ($hostname) requires a reboot to apply updates."
    fi

done

log "=== LXC Update Batch Complete ==="

if [ ${#containers_needing_reboot[@]} -gt 0 ]; then
    log "SUMMARY: The following containers require a reboot:"
    for item in "${containers_needing_reboot[@]}"; do
        log "  - $item"
    done
else
    log "SUMMARY: No containers require a reboot."
fi
