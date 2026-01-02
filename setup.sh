#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v7.0 - Timeout Safety Fix)
# Description: Installs IaC Wrapper with Anti-Hang Timeout Logic
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

echo ">>> Starting Proxmox Installation (v7.0)..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git
command -v wget >/dev/null 2>&1 || apt-get install -y wget

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes (Force Kill)
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Scripts ---"

# We perform the install manually for proxmox_dsc.sh to INJECT the new Timeout Logic
# instead of just copying it. This ensures the fix is applied even if the source file wasn't edited manually.
if [ -f "proxmox_dsc.sh" ]; then
    # Start with the source file
    cp proxmox_dsc.sh "$INSTALL_DIR/proxmox_dsc.sh"
    
    # INJECTION 1: Add the safe_exec function after "Helper Functions"
    # We use sed to insert the function definition
    sed -i '/# --- Helper Functions ---/a \
\
# Timeout Wrapper: Kills commands that hang longer than 20s\
safe_exec() {\
    timeout 20s "$@"\
    local status=$?\
    if [ $status -eq 124 ]; then\
        log "ERROR" "Command timed out: $*"\
        return 124\
    fi\
    return $status\
}' "$INSTALL_DIR/proxmox_dsc.sh"

    # INJECTION 2: Replace direct calls with safe_exec
    # This replaces "pct " with "safe_exec pct " and "qm " with "safe_exec qm "
    sed -i 's/pct /safe_exec pct /g' "$INSTALL_DIR/proxmox_dsc.sh"
    sed -i 's/qm /safe_exec qm /g' "$INSTALL_DIR/proxmox_dsc.sh"
    
    # INJECTION 3: Apply the Lock Wait fix (300s)
    sed -i 's/flock -n 200/flock -w 300 200/g' "$INSTALL_DIR/proxmox_dsc.sh"
    
    chmod +x "$INSTALL_DIR/proxmox_dsc.sh"
    echo "Installed: proxmox_dsc.sh (with Timeout Injection)"
else
    echo "ERROR: proxmox_dsc.sh not found!"
    exit 1
fi

# Install other scripts normally
install_script() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "$INSTALL_DIR/$file"
        chmod +x "$INSTALL_DIR/$file"
        echo "Installed: $file"
    fi
}
install_script "proxmox_autoupdate.sh"
install_script "proxmox_lxc_autoupdate.sh"
install_script "proxmox_iso_sync.sh"

# Install Config Files
if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# 4. Generate Wrapper (IaC) - Uses the Robust Exit Logic
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
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})

        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "Update detected (\$LOCAL -> \$REMOTE). Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR: Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "Git updated. Executing Setup..."
                    if [ -f "./setup.sh" ]; then
                        chmod +x ./setup.sh
                        ./setup.sh >> "\$LOG_FILE" 2>&1
                        log "Setup complete. Exiting clean."
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
    log "CRITICAL: Dry run failed (Exit Code \$EXIT_CODE). Aborting."
    # Log the output to see WHY it failed (e.g. timeout)
    echo "\$DRY_OUTPUT" | tee -a "\$LOG_FILE"
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

echo ">>> Installation Complete (v7.0)."
echo "    NOTE: 'safe_exec' injected. Commands will timeout after 20s."