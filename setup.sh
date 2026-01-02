#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v6.2 - Fixed Parent Process Kill Bug)
# Description: Installs IaC Wrapper, Host Update, LXC Update, and ISO Manager.
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

echo ">>> Starting Proxmox Installation (v6.2)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git
command -v wget >/dev/null 2>&1 || apt-get install -y wget

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
# FIX: Removed pkill -f "proxmox_wrapper.sh" to prevent killing the parent process during update
pkill -f "proxmox_dsc.sh" || true
pkill -f "proxmox_autoupdate.sh" || true
pkill -f "proxmox_lxc_autoupdate.sh" || true
pkill -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Scripts ---"

install_script() {
    local file=$1
    if [ -f "$file" ]; then
        if [ "$file" == "proxmox_dsc.sh" ]; then
            sed 's/flock -n 200/flock -w 60 200/g' "$file" > "$INSTALL_DIR/$file"
        else
            cp "$file" "$INSTALL_DIR/$file"
        fi
        chmod +x "$INSTALL_DIR/$file"
        echo "Installed: $file"
    else
        echo "ERROR: Required file $file not found in $REPO_DIR"
        exit 1
    fi
}

install_script "proxmox_dsc.sh"
install_script "proxmox_autoupdate.sh"
install_script "proxmox_lxc_autoupdate.sh"
install_script "proxmox_iso_sync.sh"

# Install Config Files
if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# 4. Generate Wrapper (IaC)
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] \$1" | tee -a "\$LOG_FILE"; }

# Git Auto-Update Logic
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    # Fetch updates
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})

        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "Update detected (\$LOCAL -> \$REMOTE). Pulling..."
            
            # Attempt Pull
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. \$output"
            else
                # Verify change happened
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "Git updated successfully. Executing Setup..."
                    
                    # Execute Setup directly
                    if [ -f "./setup.sh" ]; then
                        chmod +x ./setup.sh
                        # We run setup and capture its output to log
                        ./setup.sh >> "\$LOG_FILE" 2>&1
                        
                        log "Setup complete. Exiting to allow systemd to restart cleanly on next cycle."
                        exit 0
                    else
                        log "WARN: setup.sh not found after pull. Continuing with current version."
                    fi
                fi
            fi
        fi
    fi
fi

# Validation & Deployment (Only reached if no update occurred)
DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL: Dry run failed. Aborting."
    exit 1
fi
if echo "\$DRY_OUTPUT" | grep -q "FOREIGN"; then
    log "BLOCK: Foreign workloads detected. Aborting."
    echo "\$DRY_OUTPUT" | grep "FOREIGN" | tee -a "\$LOG_FILE"
    exit 0
fi
if echo "\$DRY_OUTPUT" | grep -q "ERROR"; then
    log "BLOCK: Errors detected. Aborting."
    exit 0
fi

log "Deploying..."
"\$DSC_SCRIPT" --manifest "\$STATE_FILE"
EOF
chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# 5. Log Rotation
cat <<EOF > /etc/logrotate.d/proxmox_iac
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

# 6. Systemd Units
echo "--- Installing Systemd Units ---"

# A) IaC Service
cat <<EOF > /etc/systemd/system/${SVC_IAC}.service
[Unit]
Description=Proxmox IaC GitOps Workflow
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_wrapper.sh
User=root
Nice=10
EOF

cat <<EOF > /etc/systemd/system/${SVC_IAC}.timer
[Unit]
Description=Run Proxmox IaC Workflow every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

# B) Host Auto-Update
cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.service
[Unit]
Description=Proxmox Host Auto-Update & Reboot
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_autoupdate.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.timer
[Unit]
Description=Run Proxmox Host Update (Sunday 04:00)

[Timer]
OnCalendar=Sun 04:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

# C) LXC Auto-Update
cat <<EOF > /etc/systemd/system/${SVC_LXC_UP}.service
[Unit]
Description=Proxmox LXC Container Auto-Update
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_lxc_autoupdate.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_LXC_UP}.timer
[Unit]
Description=Run LXC Auto-Update (Sunday 01:00)

[Timer]
OnCalendar=Sun 01:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

# D) ISO Sync
cat <<EOF > /etc/systemd/system/${SVC_ISO}.service
[Unit]
Description=Proxmox ISO State Reconciliation
After=network.target local-fs.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/proxmox_iso_sync.sh
User=root
EOF

cat <<EOF > /etc/systemd/system/${SVC_ISO}.timer
[Unit]
Description=Run ISO Sync (Daily 02:00)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

# 7. Activation
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete (v6.2)."
echo "    IaC Timer:         Every 2 minutes"
echo "    LXC Update Timer:  Sunday 01:00"
echo "    ISO Sync Timer:    Daily 02:00"
echo "    Host Update Timer: Sunday 04:00"