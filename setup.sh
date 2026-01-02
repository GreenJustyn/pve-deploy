#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v9.1 - Complete GitOps Installer)
# Description: Installs IaC Engine, Central Logging, Auto-Updates, and Fixes.
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

echo ">>> Starting Proxmox Installation (v9.1)..."

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

# --- PART A: Central Logging Library ---
echo "--- Installing Common Library ---"
cat <<'EOF' > "$INSTALL_DIR/common.lib"
# Proxmox IaC Common Library
MASTER_LOG="/var/log/proxmox_master.log"

log() {
    local level="$1"
    local msg="$2"
    local script_name=$(basename "$0")
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_line="[$timestamp] [$script_name] [$level] $msg"
    local local_line="[$timestamp] [$level] $msg"

    # Write to Master, Local, and Stdout
    echo "$log_line" >> "$MASTER_LOG"
    if [[ -n "${LOG_FILE:-}" ]]; then echo "$local_line" >> "$LOG_FILE"; fi
    echo "$log_line"
}

# Timeout Wrapper (Max 300s)
safe_exec() {
    local timeout_dur="300s"
    local cmd_str="$*"
    log "DEBUG" "EXEC: '$cmd_str'..."
    timeout "$timeout_dur" "$@"
    local status=$?
    if [ $status -eq 124 ]; then
        log "CRITICAL" "TIMEOUT: Command killed after $timeout_dur: $cmd_str"
        return 124
    elif [ $status -ne 0 ]; then
        log "WARN" "Command failed (Exit $status): $cmd_str"
        return $status
    fi
    return 0
}

# Cold Apply Helper (Stop -> Apply -> Start)
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
    if [ "$type" == "vm" ]; then safe_exec qm start "$vmid"; else safe_exec pct start "$vmid"; fi
}
EOF

# --- PART B: Core DSC Engine (Written directly to guarantee v9.1 Logic) ---
echo "--- Installing Core DSC Engine (v9.1) ---"
cat <<'EOF' > "$INSTALL_DIR/proxmox_dsc.sh"
#!/bin/bash
source /root/iac/common.lib
# Script: proxmox_dsc.sh (v9.1)
LOCK_FILE="/tmp/proxmox_dsc.lock"
LOG_FILE="/var/log/proxmox_dsc.log"
MANIFEST=""
DRY_RUN=false
declare -a MANAGED_VMIDS=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --manifest) MANIFEST="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
    esac; shift
done

exec 200>"$LOCK_FILE"
flock -w 300 200 || { log "WARN" "Could not acquire lock after 300s. Exiting."; exit 1; }

get_resource_status() {
    local vmid=$1
    if safe_exec pct list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_lxc"; return; fi
    if safe_exec qm list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_vm"; return; fi
    echo "missing"
}

get_power_state() {
    local vmid=$1
    local type=$2
    if [[ "$type" == "lxc" ]]; then safe_exec pct status "$vmid" | awk '{print $2}'; else safe_exec qm status "$vmid" | awk '{print $2}'; fi
}

# Smart Cloud-Init Reconciler (Fix for v9.1)
reconcile_cloudinit() {
    local vmid=$1
    local config=$2
    local storage=$3
    
    if [[ $(echo "$config" | jq -r ".cloud_init.enable") == "true" ]]; then
        local ci_user=$(echo "$config" | jq -r ".cloud_init.user")
        local ci_ssh=$(echo "$config" | jq -r ".cloud_init.sshkeys")
        local ci_ip=$(echo "$config" | jq -r ".cloud_init.ipconfig0")
        
        local cur_ide2=$(safe_exec qm config "$vmid" | grep "ide2:")
        local update_ci_settings=false
        
        # Check for Missing Drive OR Wrong Media (ISO in CloudInit slot)
        if [[ -z "$cur_ide2" ]] || (echo "$cur_ide2" | grep -q "media=cdrom" && echo "$cur_ide2" | grep -q "\.iso"); then
             log "WARN" "Drift $vmid: Cloud-Init drive missing or holding ISO. Fixing..."
             if [[ "$DRY_RUN" == "false" ]]; then
                 local store_name=$(echo "$storage" | awk -F: "{print \$1}")
                 apply_and_restart "$vmid" "vm" qm "set --ide2 ${store_name}:cloudinit"
                 update_ci_settings=true
             fi
        fi
        
        local cur_ciuser=$(safe_exec qm config "$vmid" | grep "ciuser:" | awk "{print \$2}")
        if [[ "$cur_ciuser" != "$ci_user" ]]; then
             log "INFO" "Drift $vmid: Cloud-Init User/Settings mismatch."
             update_ci_settings=true
        fi
        
        if [[ "$update_ci_settings" == "true" ]]; then
             log "INFO" "Enforcing Cloud-Init Settings for VM $vmid..."
             if [[ "$DRY_RUN" == "false" ]]; then
                 safe_exec qm set "$vmid" --ciuser "$ci_user" --sshkeys <(echo "$ci_ssh") --ipconfig0 "$ci_ip"
             fi
        fi
    fi
}

reconcile_lxc() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local template=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local swap=$(echo "$config" | jq -r '.swap // 512')
    local cores=$(echo "$config" | jq -r '.cores')
    local storage=$(echo "$config" | jq -r '.storage')
    local net0=$(echo "$config" | jq -r '.net0')
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[LXC] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    if [[ "$status" == "missing" ]]; then
        log "WARN" "LXC $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            safe_exec pct create "$vmid" "$template" --hostname "$hostname" --memory "$memory" --swap "$swap" --cores "$cores" --net0 "$net0" --rootfs "$storage" --onboot "$onboot" --protection "$protection" --features nesting=1 || return 1
            log "SUCCESS" "LXC $vmid created."
        fi
    elif [[ "$status" == "exists_vm" ]]; then
        log "ERROR" "ID Conflict: $vmid is LXC but exists as VM."
        return 1
    else
        # Drift Detection with Cold Apply
        local cur_mem=$(safe_exec pct config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --memory $memory"
        fi
        local cur_swap=$(safe_exec pct config "$vmid" | grep "swap:" | awk '{print $2}')
        if [[ "${cur_swap:-0}" != "$swap" ]]; then
            log "INFO" "Drift $vmid: Swap ${cur_swap:-0} -> $swap"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --swap $swap"
        fi
        local cur_cores=$(safe_exec pct config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --cores $cores"
        fi
        local cur_onboot=$(safe_exec pct config "$vmid" | grep "onboot:" | awk '{print $2}')
        if [[ "${cur_onboot:-0}" != "$onboot" ]]; then
            log "INFO" "Drift $vmid: OnBoot ${cur_onboot:-0} -> $onboot"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --onboot $onboot"
        fi
    fi

    local actual_state=$(get_power_state "$vmid" "lxc")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec pct start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec pct shutdown "$vmid"; fi
    fi
}

reconcile_vm() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local iso=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local cores=$(echo "$config" | jq -r '.cores')
    local sockets=$(echo "$config" | jq -r '.sockets // 1')
    local cpu_type=$(echo "$config" | jq -r '.cpu // "kvm64"')
    local net0=$(echo "$config" | jq -r '.net0')
    local storage=$(echo "$config" | jq -r '.storage')
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[VM] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    if [[ "$status" == "missing" ]]; then
        log "WARN" "VM $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            if safe_exec qm create "$vmid" --name "$hostname" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --scsi0 "$storage" --cdrom "$iso" --scsihw virtio-scsi-pci --boot order=scsi0;ide2;net0 --onboot "$onboot" --protection "$protection"; then
                if [[ $(echo "$config" | jq -r '.cloud_init.enable') == "true" ]]; then
                    reconcile_cloudinit "$vmid" "$config" "$storage"
                fi
                log "SUCCESS" "VM $vmid created."
            fi
        fi
    elif [[ "$status" == "exists_lxc" ]]; then
        log "ERROR" "ID Conflict: $vmid is VM but exists as LXC."
        return 1
    else
        # Drift Detection
        local cur_mem=$(safe_exec qm config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --memory $memory"
        fi
        local cur_cores=$(safe_exec qm config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cores $cores"
        fi
        local cur_cpu=$(safe_exec qm config "$vmid" | grep "cpu:" | awk '{print $2}')
        if [[ "${cur_cpu:-kvm64}" != "$cpu_type" ]]; then
            log "WARN" "Drift $vmid: CPU Type ${cur_cpu:-kvm64} -> $cpu_type"
            [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cpu $cpu_type"
        fi
        local cur_net0=$(safe_exec qm config "$vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
        if [[ "$cur_net0" != "$net0" ]]; then
             log "INFO" "Drift $vmid: Network Config Changed."
             [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --net0 $net0"
        fi

        # Cloud-Init Check
        reconcile_cloudinit "$vmid" "$config" "$storage"
    fi

    local actual_state=$(get_power_state "$vmid" "vm")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm shutdown "$vmid"; fi
    fi
}

reconcile_dispatch() {
    local config="$1"
    local type=$(echo "$config" | jq -r '.type')
    local vmid=$(echo "$config" | jq -r '.vmid')
    MANAGED_VMIDS+=("$vmid")
    if [[ "$type" == "lxc" ]]; then reconcile_lxc "$config"; elif [[ "$type" == "vm" ]]; then reconcile_vm "$config"; fi
}

detect_unmanaged_workloads() {
    log "INFO" "Starting Audit for Unmanaged Workloads..."
    local lxc_list=$(safe_exec pct list 2>/dev/null | awk 'NR>1 {print $1}')
    local vm_list=$(safe_exec qm list 2>/dev/null | awk 'NR>1 {print $1}')
    local all_vms="$lxc_list"$'\n'"$vm_list"
    local found_foreign=false
    for host_vmid in $all_vms; do
        [[ -z "$host_vmid" ]] && continue
        local is_managed=false
        for managed_id in "${MANAGED_VMIDS[@]}"; do if [[ "$host_vmid" == "$managed_id" ]]; then is_managed=true; break; fi; done
        if [[ "$is_managed" == "false" ]]; then
            found_foreign=true
            log "WARN" "FOREIGN DETECTED: VMID $host_vmid"
        fi
    done
    if [[ "$found_foreign" == "true" ]]; then echo "FOREIGN WORKLOADS FOUND"; fi
}

log "INFO" "Run Started. Processing Manifest: $MANIFEST"
for row in $(cat "$MANIFEST" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
    current_config=$(echo ${row} | base64 --decode)
    reconcile_dispatch "$current_config"
done
detect_unmanaged_workloads
log "INFO" "Run complete."
EOF
chmod +x "$INSTALL_DIR/proxmox_dsc.sh"

# --- PART C: Install & Patch Other Scripts ---
echo "--- Patching & Installing Auxiliary Scripts ---"

# Function to patch a script to use common.lib and remove local logs
install_and_patch() {
    local filename=$1
    if [ -f "$filename" ]; then
        cp "$filename" "$INSTALL_DIR/$filename"
        # 1. Remove local log() function
        sed -i '/^log() {/,/^}/d' "$INSTALL_DIR/$filename"
        # 2. Inject source common.lib
        sed -i '2i source /root/iac/common.lib' "$INSTALL_DIR/$filename"
        chmod +x "$INSTALL_DIR/$filename"
        echo "Installed: $filename"
    fi
}
install_and_patch "proxmox_autoupdate.sh"
install_and_patch "proxmox_lxc_autoupdate.sh"
install_and_patch "proxmox_iso_sync.sh"

# Config Files
if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# --- PART D: Wrapper (with Central Logging) ---
cat <<EOF > "$INSTALL_DIR/proxmox_wrapper.sh"
#!/bin/bash
source /root/iac/common.lib
INSTALL_DIR="/root/iac"
REPO_DIR="$REPO_DIR" 
DSC_SCRIPT="\$INSTALL_DIR/proxmox_dsc.sh"
STATE_FILE="\$INSTALL_DIR/state.json"
LOG_FILE="/var/log/proxmox_dsc.log"

if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    if git fetch origin 2>/dev/null; then
        LOCAL=\$(git rev-parse HEAD)
        REMOTE=\$(git rev-parse @{u})
        if [ "\$LOCAL" != "\$REMOTE" ]; then
            log "INFO" "Update detected. Pulling..."
            if ! output=\$(git pull 2>&1); then
                log "ERROR" "Git pull failed. \$output"
            else
                if [ "\$(git rev-parse HEAD)" != "\$LOCAL" ]; then
                    log "INFO" "Git updated. Re-running Setup..."
                    [ -f "./setup.sh" ] && chmod +x ./setup.sh && ./setup.sh >> "\$LOG_FILE" 2>&1
                    exit 0
                fi
            fi
        fi
    fi
fi

DRY_OUTPUT=\$("\$DSC_SCRIPT" --manifest "\$STATE_FILE" --dry-run 2>&1)
EXIT_CODE=\$?

if [ \$EXIT_CODE -ne 0 ]; then
    log "CRITICAL" "Dry run failed."
    echo "\$DRY_OUTPUT" | tee -a "\$LOG_FILE"
    exit 1
fi
if echo "\$DRY_OUTPUT" | grep -q "FOREIGN"; then
    log "WARN" "BLOCK: Foreign workloads detected."
    echo "\$DRY_OUTPUT" | grep "FOREIGN" | tee -a "\$LOG_FILE"
    exit 0
fi
if echo "\$DRY_OUTPUT" | grep -q "ERROR"; then
    log "WARN" "BLOCK: Errors detected."
    exit 0
fi

log "INFO" "Deploying..."
"\$DSC_SCRIPT" --manifest "\$STATE_FILE"
EOF
chmod +x "$INSTALL_DIR/proxmox_wrapper.sh"

# --- PART E: Log Rotation & Units ---
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

# Reload Systemd (Units presumed installed by previous runs, just reload config)
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete (v9.1)."
echo "    Core Engine Rewritten with Cloud-Init Fix & Central Logging."