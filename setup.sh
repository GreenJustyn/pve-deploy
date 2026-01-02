#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v9.0 - Central Logging & High Verbosity)
# Description: Installs Centralized Logging, Master Log, and Verbose Execution
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd)

# Service Names
SVC_IAC="proxmox-iac"
SVC_HOST_UP="proxmox-autoupdate"
SVC_LXC_UP="proxmox-lxc-autoupdate"
SVC_ISO="proxmox-iso-sync"

echo ">>> Starting Proxmox Installation (v9.0)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git
command -v wget >/dev/null 2>&1 || apt-get install -y wget

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# --- NEW: Create Common Library ---
cat <<'EOF' > "$INSTALL_DIR/common.lib"
# Proxmox IaC Common Library
MASTER_LOG="/var/log/proxmox_master.log"

# Unified Logger
# Usage: log "LEVEL" "Message"
log() {
    local level="$1"
    local msg="$2"
    local script_name=$(basename "$0")
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Construct the Log Line
    local log_line="[$timestamp] [$script_name] [$level] $msg"
    local local_line="[$timestamp] [$level] $msg"

    # 1. Write to Master Log
    echo "$log_line" >> "$MASTER_LOG"

    # 2. Write to Local Log (if defined by the script)
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$local_line" >> "$LOG_FILE"
    fi

    # 3. Output to Stdout (for Systemd Journal)
    echo "$log_line"
}

# Verbose Execution Wrapper with Timeout
# Usage: safe_exec command arg1 arg2 ...
safe_exec() {
    local timeout_dur="300s"
    local cmd_str="$*"
    
    # Verbose Start
    log "DEBUG" "EXEC: '$cmd_str' (Max: $timeout_dur)..."

    # Execute with Timeout
    timeout "$timeout_dur" "$@"
    local status=$?

    # Handle Results
    if [ $status -eq 124 ]; then
        log "CRITICAL" "TIMEOUT REACHED: Command ran for >$timeout_dur and was killed: $cmd_str"
        return 124
    elif [ $status -ne 0 ]; then
        log "WARN" "Command failed (Exit $status): $cmd_str"
        return $status
    else
        # Optional: Log success for very long running commands?
        # log "DEBUG" "Success: $cmd_str"
        return 0
    fi
}

# Cold Apply Helper
apply_and_restart() {
    local vmid=$1
    local type=$2
    local cmd=$3
    local args=$4
    
    log "ACTION" "Stopping $type $vmid to apply changes..."
    if [ "$type" == "vm" ]; then
        safe_exec qm shutdown "$vmid" && sleep 5
        if qm status "$vmid" | grep -q running; then safe_exec qm stop "$vmid"; fi
    else
        safe_exec pct shutdown "$vmid" && sleep 5
        if pct status "$vmid" | grep -q running; then safe_exec pct stop "$vmid"; fi
    fi
    
    log "ACTION" "Applying Change: $cmd $vmid $args"
    safe_exec $cmd "$vmid" $args
    
    log "ACTION" "Starting $type $vmid..."
    if [ "$type" == "vm" ]; then
        safe_exec qm start "$vmid"
    else
        safe_exec pct start "$vmid"
    fi
}
EOF

# 3. Install & Patch Scripts
echo "--- Installing & Patching Scripts ---"

# Helper to copy and patch a script
install_and_patch() {
    local filename=$1
    if [ -f "$filename" ]; then
        # Copy to install dir
        cp "$filename" "$INSTALL_DIR/$filename"
        
        # PATCH 1: Remove local log() function definitions
        # We delete lines starting with 'log() {' down to the closing '}'
        # This relies on the function being formatted normally.
        sed -i '/^log() {/,/^}/d' "$INSTALL_DIR/$filename"
        
        # PATCH 2: Remove old safe_exec/apply functions if they exist (to avoid dupes)
        sed -i '/^safe_exec() {/,/^}/d' "$INSTALL_DIR/$filename"
        sed -i '/^apply_and_restart() {/,/^}/d' "$INSTALL_DIR/$filename"

        # PATCH 3: Inject "source common.lib" after the shebang
        sed -i '2i source /root/iac/common.lib' "$INSTALL_DIR/$filename"
        
        # PATCH 4: Ensure variables are set for the logger
        # proxmox_iso_sync doesn't define LOG_FILE variable usually, let's ensure it does if missing
        # (Actually your scripts do define LOG_FILE, so this is fine)
        
        chmod +x "$INSTALL_DIR/$filename"
        echo "Installed & Patched: $filename"
    else
        echo "WARN: $filename not found in repo."
    fi
}

install_and_patch "proxmox_dsc.sh"
install_and_patch "proxmox_autoupdate.sh"
install_and_patch "proxmox_lxc_autoupdate.sh"
install_and_patch "proxmox_iso_sync.sh"

# Post-Patching specifics for DSC (Drift Logic)
# Since we removed safe_exec/apply definitions above, we need to ensure the script USES them.
# The v8.0 injection logic for 'pct set' -> 'apply_and_restart' is still needed if not present in source.
# We re-run the sed replacements for usage:

TGT="$INSTALL_DIR/proxmox_dsc.sh"
sed -i 's/pct set "\$vmid"/apply_and_restart "\$vmid" "lxc" pct/g' "$TGT"
sed -i 's/qm set "\$vmid"/apply_and_restart "\$vmid" "vm" qm/g' "$TGT"
sed -i 's/pct list/safe_exec pct list/g' "$TGT"
sed -i 's/qm list/safe_exec qm list/g' "$TGT"
sed -i 's/pct /safe_exec pct /g' "$TGT"
sed -i 's/qm /safe_exec qm /g' "$TGT"
# Fix the safe_exec double-wrap if run multiple times (safe_exec safe_exec)
sed -i 's/safe_exec safe_exec/safe_exec/g' "$TGT"

# Install Config Files
if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# 4. Generate Wrapper (IaC) - Also needs patching
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
source /root/iac/common.lib
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

# Git Auto-Update Logic
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})

        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "INFO" "Update detected (\$LOCAL -> \$REMOTE). Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR" "Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "INFO" "Git updated. Executing Setup..."
                    if [ -f "./setup.sh" ]; then
                        chmod +x ./setup.sh
                        ./setup.sh >> "\$LOG_FILE" 2>&1
                        log "INFO" "Setup complete. Exiting clean."
                        exit 0
                    fi
                fi
            fi
        fi
    fi
fi

# Validation & Deployment
DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL" "Dry run failed (Exit Code \$EXIT_CODE). Aborting."
    echo "\$DRY_OUTPUT" | tee -a "\$LOG_FILE"
    exit 1
fi

if echo "\$DRY_OUTPUT" | grep -q "FOREIGN"; then
    log "WARN" "BLOCK: Foreign workloads detected. Aborting."
    echo "\$DRY_OUTPUT" | grep "FOREIGN" | tee -a "\$LOG_FILE"
    exit 0
fi

if echo "\$DRY_OUTPUT" | grep -q "ERROR"; then
    log "WARN" "BLOCK: Errors detected. Aborting."
    exit 0
fi

log "INFO" "Deploying..."
"\$DSC_SCRIPT" --manifest "\$STATE_FILE"
EOF
chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# 5. Log Rotation (Include Master Log)
cat <<EOF > /etc/logrotate.d/proxmox_iac
/var/log/proxmox_master.log
/var/log/proxmox_dsc.log 
/var/log/proxmox_autoupdate.log
/var/log/proxmox_lxc_autoupdate.log
/var/log/proxmox_iso_sync.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 10M
}
EOF

# 6. Systemd Units (Standard - Unchanged)
# (For brevity in v9.0, we just reload the existing ones as they haven't changed structure)
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete (v9.0)."
echo "    FEATURE: Central Logging Active (/var/log/proxmox_master.log)"
echo "    FEATURE: Verbose Execution Logging Active"