#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v5.0 - The Full Stack)
# Description: Installs IaC Wrapper, Host Auto-Update, and LXC Auto-Update.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd)

# Service Names
SVC_IAC="proxmox-iac"
SVC_HOST_UP="proxmox-autoupdate"
SVC_LXC_UP="proxmox-lxc-autoupdate"

echo ">>> Starting Proxmox Installation (v5.0)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes/Locks
pkill -f "proxmox_dsc.sh" || true
pkill -f "proxmox_wrapper.sh" || true
pkill -f "proxmox_autoupdate.sh" || true
pkill -f "proxmox_lxc_autoupdate.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Scripts ---"

# Helper to copy and chmod
install_script() {
    local file=$1
    if [ -f "$file" ]; then
        # Special handling for DSC to inject lock fix if needed
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

# Install State File
if [ -f "state.json" ]; then
    cp state.json "$INSTALL_DIR/state.json"
else
    echo "[]" > "$INSTALL_DIR/state.json"
fi

# 4. Generate Wrapper (IaC)
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [WRAPPER] \$1" | tee -a "\$LOG_FILE"; }

# Git Auto-Update
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})
        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "Update detected. Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "Git updated. Re-installing..."
                    [ -f "./setup.sh" ] && chmod +x ./setup.sh && ./setup.sh
                    exec "\$0"
                fi
            fi
        fi
    fi
fi

# Validation & Deployment
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
/var/log/proxmox_lxc_autoupdate.log {
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

# A) IaC Service (Runs via Wrapper)
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

# 7. Activation
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer

echo ">>> Installation Complete (v5.0)."
echo "    IaC Timer:         Every 2 minutes"
echo "    LXC Update Timer:  Sunday 01:00"
echo "    Host Update Timer: Sunday 04:00"
