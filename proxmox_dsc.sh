#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_dsc.sh (v3.1 - Unified & Fixed)
# Description: Idempotent Proxmox IaC Manager for Containers (LXC) and VMs (QEMU)
#              Includes Foreign Workload Detection & JSON Auto-Generation.
# OS: Debian 13 (Proxmox Host)
# Dependencies: jq, pct, qm
# Usage: ./proxmox_dsc.sh --manifest /path/to/state.json [--dry-run]
# -----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
LOCK_FILE="/tmp/proxmox_dsc.lock"
LOG_FILE="/var/log/proxmox_dsc.log"

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variables ---
MANIFEST=""
DRY_RUN=false
declare -a MANAGED_VMIDS=()

# --- Logging Helper ---
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Print to console if interactive or dry-run, always log to file
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# --- Input Parsing ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --manifest) MANIFEST="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$MANIFEST" ]]; then
    echo "Error: Manifest file required. Usage: $0 --manifest <path> [--dry-run]"
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: Manifest file not found at $MANIFEST"
    exit 1
fi

# --- Locking Mechanism ---
exec 200>"$LOCK_FILE"
flock -n 200 || { log "WARN" "Script is already running. Exiting."; exit 1; }

# --- Helper Functions ---

# Check if ID exists in either LXC or QM
get_resource_status() {
    local vmid=$1
    if pct list 2>/dev/null | grep -q "^$vmid "; then echo "exists_lxc"; return; fi
    if qm list 2>/dev/null | grep -q "^$vmid "; then echo "exists_vm"; return; fi
    echo "missing"
}

get_power_state() {
    local vmid=$1
    local type=$2
    if [[ "$type" == "lxc" ]]; then
        pct status "$vmid" | awk '{print $2}'
    else
        qm status "$vmid" | awk '{print $2}'
    fi
}

# --- RECONCILIATION LOGIC: LXC ---
reconcile_lxc() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local template=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local cores=$(echo "$config" | jq -r '.cores')
    local storage=$(echo "$config" | jq -r '.storage') # maps to rootfs
    local net0=$(echo "$config" | jq -r '.net0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[LXC] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    # 1. CREATE
    if [[ "$status" == "missing" ]]; then
        log "WARN" "LXC $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            pct create "$vmid" "$template" --hostname "$hostname" --memory "$memory" --cores "$cores" --net0 "$net0" --rootfs "$storage" --features nesting=1 || return 1
            log "SUCCESS" "LXC $vmid created."
        else
            log "DRY-RUN" "Would execute: pct create $vmid ..."
        fi
    elif [[ "$status" == "exists_vm" ]]; then
        log "ERROR" "ID Conflict: $vmid is defined as LXC but exists as VM. Skipping."
        return 1
    else
        # 2. DRIFT (Simplified)
        local cur_mem=$(pct config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            if [[ "$DRY_RUN" == "false" ]]; then pct set "$vmid" --memory "$memory"; fi
        fi
        
        local cur_cores=$(pct config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            if [[ "$DRY_RUN" == "false" ]]; then pct set "$vmid" --cores "$cores"; fi
        fi
    fi

    # 3. POWER STATE
    local actual_state=$(get_power_state "$vmid" "lxc")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then pct start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then pct shutdown "$vmid"; fi
    fi
}

# --- RECONCILIATION LOGIC: VM (QEMU) ---
reconcile_vm() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local iso=$(echo "$config" | jq -r '.template') # For VMs, template usually means ISO or Clone source
    local memory=$(echo "$config" | jq -r '.memory')
    local cores=$(echo "$config" | jq -r '.cores')
    local storage=$(echo "$config" | jq -r '.storage') # maps to scsi0 disk size
    local net0=$(echo "$config" | jq -r '.net0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[VM] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    # 1. CREATE
    if [[ "$status" == "missing" ]]; then
        log "WARN" "VM $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            # Note: QM create is complex. This assumes a basic Create from ISO approach.
            qm create "$vmid" --name "$hostname" --memory "$memory" --cores "$cores" --net0 "$net0" --scsi0 "$storage" --cdrom "$iso" --scsihw virtio-scsi-pci --boot order=scsi0;ide2;net0 || return 1
            log "SUCCESS" "VM $vmid created."
        else
            log "DRY-RUN" "Would execute: qm create $vmid ..."
        fi
    elif [[ "$status" == "exists_lxc" ]]; then
        log "ERROR" "ID Conflict: $vmid is defined as VM but exists as LXC. Skipping."
        return 1
    else
        # 2. DRIFT
        local cur_mem=$(qm config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then
            log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"
            if [[ "$DRY_RUN" == "false" ]]; then qm set "$vmid" --memory "$memory"; fi
        fi

        local cur_cores=$(qm config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then
            log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"
            if [[ "$DRY_RUN" == "false" ]]; then qm set "$vmid" --cores "$cores"; fi
        fi
    fi

    # 3. POWER STATE
    local actual_state=$(get_power_state "$vmid" "vm")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then qm start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then qm shutdown "$vmid"; fi
    fi
}

# --- DISPATCHER ---
reconcile_dispatch() {
    local config="$1"
    local type=$(echo "$config" | jq -r '.type')
    local vmid=$(echo "$config" | jq -r '.vmid')

    MANAGED_VMIDS+=("$vmid")

    if [[ "$type" == "lxc" ]]; then
        reconcile_lxc "$config"
    elif [[ "$type" == "vm" ]]; then
        reconcile_vm "$config"
    else
        log "ERROR" "Unknown type '$type' for VMID $vmid"
    fi
}

# --- FOREIGN WORKLOAD DETECTION (Detailed JSON Output) ---
detect_unmanaged_workloads() {
    log "INFO" "Starting Audit for Unmanaged Workloads..."
    
    # 1. Get LXC List (Skipping header)
    local lxc_list=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    
    # 2. Get VM List (Skipping header)
    local vm_list=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')

    # FIX: Concatenate with a Newline, not a space, to respect IFS=$'\n\t'
    local all_vms="$lxc_list"$'\n'"$vm_list"

    # Flag to track findings
    local found_foreign=false

    for host_vmid in $all_vms; do
        # Skip empty lines resulting from the merge
        [[ -z "$host_vmid" ]] && continue

        local is_managed=false
        for managed_id in "${MANAGED_VMIDS[@]}"; do
            if [[ "$host_vmid" == "$managed_id" ]]; then is_managed=true; break; fi
        done

        if [[ "$is_managed" == "false" ]]; then
            found_foreign=true
            
            # Determine Type
            local r_type="unknown"
            if pct status "$host_vmid" &>/dev/null; then r_type="lxc"; fi
            if qm status "$host_vmid" &>/dev/null; then r_type="vm"; fi

            log "WARN" "FOREIGN $r_type DETECTED: VMID $host_vmid"
            
            # --- Generate Valid JSON for LXC ---
            if [[ "$r_type" == "lxc" ]]; then
                 local d_name=$(pct config "$host_vmid" | grep "hostname:" | awk '{print $2}')
                 local d_mem=$(pct config "$host_vmid" | grep "memory:" | awk '{print $2}')
                 local d_cores=$(pct config "$host_vmid" | grep "cores:" | awk '{print $2}')
                 local d_net=$(pct config "$host_vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
                 local d_root=$(pct config "$host_vmid" | grep "rootfs:" | awk '{$1=""; print $0}' | xargs)

                 echo -e "\n${YELLOW}--- SUGGESTED JSON IMPORT FOR LXC $host_vmid ---${NC}"
                 echo "  {"
                 echo "    \"type\": \"lxc\","
                 echo "    \"vmid\": $host_vmid,"
                 echo "    \"hostname\": \"${d_name:-unknown}\","
                 echo "    \"template\": \"local:vztmpl/EXISTING\","
                 echo "    \"memory\": ${d_mem:-512},"
                 echo "    \"cores\": ${d_cores:-1},"
                 echo "    \"net0\": \"${d_net:-name=eth0,bridge=vmbr0,ip=dhcp}\","
                 echo "    \"storage\": \"${d_root:-local-lvm:8}\","
                 echo "    \"state\": \"running\""
                 echo "  },"

            # --- Generate Valid JSON for VM (QEMU) ---
            elif [[ "$r_type" == "vm" ]]; then
                 local d_name=$(qm config "$host_vmid" | grep "name:" | awk '{print $2}')
                 local d_mem=$(qm config "$host_vmid" | grep "memory:" | awk '{print $2}')
                 local d_cores=$(qm config "$host_vmid" | grep "cores:" | awk '{print $2}')
                 # Extract net0, remove key 'net0:', trim whitespace
                 local d_net=$(qm config "$host_vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
                 # Extract scsi0 (or ide0/sata0 if scsi0 missing) for storage hint
                 local d_store=$(qm config "$host_vmid" | grep "scsi0:" | awk '{$1=""; print $0}' | xargs)

                 echo -e "\n${YELLOW}--- SUGGESTED JSON IMPORT FOR VM $host_vmid ---${NC}"
                 echo "  {"
                 echo "    \"type\": \"vm\","
                 echo "    \"vmid\": $host_vmid,"
                 echo "    \"hostname\": \"${d_name:-vm$host_vmid}\","
                 echo "    \"template\": \"local:iso/EXISTING\","
                 echo "    \"memory\": ${d_mem:-1024},"
                 echo "    \"cores\": ${d_cores:-1},"
                 echo "    \"net0\": \"${d_net:-virtio,bridge=vmbr0}\","
                 echo "    \"storage\": \"${d_store:-local-lvm:32}\","
                 echo "    \"state\": \"running\""
                 echo "  },"
            fi
        fi
    done
    
    if [[ "$found_foreign" == "true" ]]; then
        echo -e "\n${YELLOW}Copy the blocks above into your state.json to adopt these resources.${NC}"
    fi
}

# --- Main Execution ---
log "INFO" "Run Started. Processing Manifest: $MANIFEST"

# Iterate through JSON array
for row in $(cat "$MANIFEST" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
    current_config=$(echo ${row} | base64 --decode)
    reconcile_dispatch "$current_config"
done

# Run Post-Execution Audit
detect_unmanaged_workloads

log "INFO" "Run complete."
