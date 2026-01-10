#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh (v10.1 - The "All-in-One" Release)
# Description: Includes Central Logging (Fixed), Cloning Support, and ISO Variables.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
REPO_DIR=$(pwd)
SVC_IAC="proxmox-iac"
SVC_HOST_UP="proxmox-autoupdate"
SVC_LXC_UP="proxmox-lxc-autoupdate"
SVC_ISO="proxmox-iso-sync"

echo ">>> Starting Proxmox Installation (v10.1)..."

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

# --- PART A: Central Logging Library (v9.2 Fix) ---
echo "--- Installing Common Library (v9.2 Stderr Fix) ---"
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

    # 1. Write to Master Log
    echo "$log_line" >> "$MASTER_LOG"
    
    # 2. Write to Local Log
    if [[ -n "${LOG_FILE:-}" ]]; then echo "$local_line" >> "$LOG_FILE"; fi

    # 3. Output to Stderr (CRITICAL FIX: Prevents variable capture pollution)
    echo "$log_line" >&2
}

# Timeout Wrapper (Max 300s)
safe_exec() {
    local timeout_dur="300s"
    local cmd_str="$*"
    log "DEBUG" "EXEC: '$cmd_str'..."
    
    # Run command, capturing stdout normally, but errors flow to stderr
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
    if [ "$type" == "vm" ]; then safe_exec qm start "$vmid"; else safe_exec pct start "$vmid"; fi
}
EOF

# --- PART B: Core DSC Engine (v10.0 Cloning Logic) ---
echo "--- Installing Core DSC Engine (v10.0 Cloning Support) ---"
cat <<'EOF' > "$INSTALL_DIR/proxmox_dsc.sh"
#!/bin/bash
source /root/iac/common.lib
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
        if [[ "$cur_ciuser" != "$ci_user" ]]; then log "INFO" "Drift $vmid: Cloud-Init User/Settings mismatch."; update_ci_settings=true; fi
        if [[ "$update_ci_settings" == "true" ]]; then
             log "INFO" "Enforcing Cloud-Init Settings for VM $vmid..."
             if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm set "$vmid" --ciuser "$ci_user" --sshkeys <(echo "$ci_ssh") --ipconfig0 "$ci_ip"; fi
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
        local cur_mem=$(safe_exec pct config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --memory $memory"; fi
        local cur_swap=$(safe_exec pct config "$vmid" | grep "swap:" | awk '{print $2}')
        if [[ "${cur_swap:-0}" != "$swap" ]]; then log "INFO" "Drift $vmid: Swap ${cur_swap:-0} -> $swap"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --swap $swap"; fi
        local cur_cores=$(safe_exec pct config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --cores $cores"; fi
        local cur_onboot=$(safe_exec pct config "$vmid" | grep "onboot:" | awk '{print $2}')
        if [[ "${cur_onboot:-0}" != "$onboot" ]]; then log "INFO" "Drift $vmid: OnBoot ${cur_onboot:-0} -> $onboot"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --onboot $onboot"; fi
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
    local template=$(echo "$config" | jq -r '.template') # Can be ISO path OR Template ID
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
        log "WARN" "VM $vmid missing. Provisioning..."
        if [[ "$DRY_RUN" == "false" ]]; then
            # v10.0 CLONING SUPPORT
            if [[ "$template" =~ ^[0-9]+$ ]]; then
                log "ACTION" "Cloning from Template ID $template..."
                local store_target=$(echo "$storage" | awk -F: '{print $1}')
                safe_exec qm clone "$template" "$vmid" --name "$hostname" --full 1 --storage "$store_target"
                safe_exec qm set "$vmid" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --onboot "$onboot" --protection "$protection"
            else
                log "ACTION" "Creating Blank VM from ISO..."
                safe_exec qm create "$vmid" --name "$hostname" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --scsi0 "$storage" --cdrom "$template" --scsihw virtio-scsi-pci --boot order=scsi0;ide2;net0 --onboot "$onboot" --protection "$protection"
            fi
            
            if [[ $(echo "$config" | jq -r '.cloud_init.enable') == "true" ]]; then reconcile_cloudinit "$vmid" "$config" "$storage"; fi
            log "SUCCESS" "VM $vmid provisioned."
        fi
    elif [[ "$status" == "exists_lxc" ]]; then
        log "ERROR" "ID Conflict: $vmid is VM but exists as LXC."
        return 1
    else
        local cur_mem=$(safe_exec qm config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --memory $memory"; fi
        local cur_cores=$(safe_exec qm config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cores $cores"; fi
        local cur_cpu=$(safe_exec qm config "$vmid" | grep "cpu:" | awk '{print $2}')
        if [[ "${cur_cpu:-kvm64}" != "$cpu_type" ]]; then log "WARN" "Drift $vmid: CPU Type ${cur_cpu:-kvm64} -> $cpu_type"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cpu $cpu_type"; fi
        local cur_net0=$(safe_exec qm config "$vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
        if [[ "$cur_net0" != "$net0" ]]; then log "INFO" "Drift $vmid: Network Config Changed."; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --net0 $net0"; fi
        
        # v10.0 DISK RESIZE
        local req_size=$(echo "$storage" | awk -F: '{print $2}')
        local cur_size_raw=$(safe_exec qm config "$vmid" | grep "scsi0:" | grep -o "size=[0-9]*G" | grep -o "[0-9]*")
        if [[ -n "$req_size" && -n "$cur_size_raw" ]]; then
            if (( req_size > cur_size_raw )); then
                log "WARN" "Drift $vmid: Disk Size ${cur_size_raw}G -> ${req_size}G. Resizing..."
                [[ "$DRY_RUN" == "false" ]] && safe_exec qm resize "$vmid" scsi0 "${req_size}G"
            fi
        fi

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

# --- PART C: ISO Sync Script (v10.1 Variable Support) ---
echo "--- Installing ISO Sync Script (v10.1 Variables) ---"
cat <<'EOF' > "$INSTALL_DIR/proxmox_iso_sync.sh"
#!/bin/bash
source /root/iac/common.lib
LOG_FILE="/var/log/proxmox_iso_sync.log"
MANIFEST="/root/iac/iso-images.json"
STORAGE_ID="local"

if ! command -v jq &> /dev/null; then log "ERROR" "jq missing."; exit 1; fi
if [ ! -f "$MANIFEST" ]; then log "ERROR" "Manifest missing."; exit 1; fi

STORAGE_PATH=$(safe_exec pvesm path "$STORAGE_ID:iso" 2>/dev/null | xargs dirname 2>/dev/null)
if [ -z "$STORAGE_PATH" ] || [ "$STORAGE_PATH" == "." ]; then STORAGE_PATH="/var/lib/vz/template/iso"; fi
if [ ! -d "$STORAGE_PATH" ]; then log "ERROR" "Path $STORAGE_PATH not found."; exit 1; fi

log "INFO" "Syncing ISOs to $STORAGE_PATH..."
declare -a KEPT_FILES=()
COUNT=$(jq '. | length' "$MANIFEST")

for ((i=0; i<$COUNT; i++)); do
    OS=$(jq -r ".[$i].os" "$MANIFEST")
    PAGE=$(jq -r ".[$i].source_page" "$MANIFEST")
    PATTERN=$(jq -r ".[$i].pattern" "$MANIFEST")
    VERSION=$(jq -r ".[$i].version // empty" "$MANIFEST")

    if [[ -n "$VERSION" ]]; then
        # v10.1 Variable Mode
        LATEST_FILE="${PATTERN//\$\{version\}/$VERSION}"
        if [[ "$PAGE" == *"github.com"* && "$PAGE" == *"download/" ]]; then DOWNLOAD_URL="${PAGE}${VERSION}/${LATEST_FILE}"; else DOWNLOAD_URL="${PAGE}${LATEST_FILE}"; fi
        log "CHECKING: $OS (Pinned: $VERSION)..."
    else
        # Dynamic Scraper Mode
        log "CHECKING: $OS (Scraping: $PATTERN)..."
        LATEST_FILE=$(curl -sL "$PAGE" | grep -oP "$PATTERN" | sort -V | tail -n 1)
        if [ -z "$LATEST_FILE" ]; then log "WARN" "Could not scrape file for $OS"; continue; fi
        if [[ "$PAGE" == */ ]]; then DOWNLOAD_URL="${PAGE}${LATEST_FILE}"; else DOWNLOAD_URL="${PAGE}/${LATEST_FILE}"; fi
    fi

    TARGET_FILE="$STORAGE_PATH/$LATEST_FILE"
    KEPT_FILES+=("$LATEST_FILE")
    if [ -f "$TARGET_FILE" ]; then
        log "OK: $LATEST_FILE exists."
    else
        log "NEW: $LATEST_FILE found."
        log "ACTION" "Downloading $DOWNLOAD_URL..."
        if safe_exec wget -q --show-progress -O "${TARGET_FILE}.tmp" "$DOWNLOAD_URL"; then
            mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
            log "SUCCESS" "Downloaded $LATEST_FILE"
        else
            log "ERROR" "Download failed for $LATEST_FILE"
            rm -f "${TARGET_FILE}.tmp"
        fi
    fi
done

EXISTING_FILES=$(ls "$STORAGE_PATH"/*.iso "$STORAGE_PATH"/*.qcow2 "$STORAGE_PATH"/*.xz 2>/dev/null | xargs -n 1 basename)
for file in $EXISTING_FILES; do
    is_kept=false
    for kept in "${KEPT_FILES[@]}"; do if [[ "$file" == "$kept" ]]; then is_kept=true; break; fi; done
    if [ "$is_kept" == "false" ]; then log "DELETE" "Obsolete file: $file"; rm -f "$STORAGE_PATH/$file"; fi
done
EOF
chmod +x "$INSTALL_DIR/proxmox_iso_sync.sh"

# --- PART D: Patching & Installing Auxiliary Scripts ---
install_and_patch() {
    local filename=$1
    if [ -f "$filename" ]; then
        cp "$filename" "$INSTALL_DIR/$filename"
        sed -i '/^log() {/,/^}/d' "$INSTALL_DIR/$filename"
        sed -i '2i source /root/iac/common.lib' "$INSTALL_DIR/$filename"
        chmod +x "$INSTALL_DIR/$filename"
        echo "Installed: $filename"
    fi
}
install_and_patch "proxmox_autoupdate.sh"
install_and_patch "proxmox_lxc_autoupdate.sh"

if [ -f "state.json" ]; then cp state.json "$INSTALL_DIR/state.json"; else echo "[]" > "$INSTALL_DIR/state.json"; fi
if [ -f "iso-images.json" ]; then cp iso-images.json "$INSTALL_DIR/iso-images.json"; else echo "[]" > "$INSTALL_DIR/iso-images.json"; fi

# --- PART E: Wrapper ---
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

# --- PART F: Log Rotation & Units ---
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

systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete (v10.1)."
echo "    FEATURES: Central Logging (Stderr Fix), Cloning/Resize, ISO Variables."