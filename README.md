# Proxmox IaC: Idempotent Desired State Configuration

This repository contains a lightweight, bash-based Infrastructure as Code (IaC) solution for Proxmox VE. It utilizes a **Desired State Configuration (DSC)** methodology to ensure that Virtual Machines (QEMU) and Containers (LXC) strictly match a defined JSON manifest.

The solution is designed to be **self-healing**, **idempotent**, and **safe**, operating on a strict "GitOps" workflow.

🚀 Capabilities
1. Desired State Configuration (IaC)
Unified Management: Controls Virtual Machines (QEMU) and Containers (LXC) from a single state.json manifest.
Drift Detection: Automatically corrects configuration drift (RAM, Cores, Hostname) and enforces Power State.
Foreign Workload Protection: Blocks deployment if "Unmanaged" resources are detected on the host, preventing accidental overlaps.

2. Automated Host Maintenance
OS Updates: Automatically performs apt-get update and dist-upgrade for Proxmox VE.
Safe Reboots: Performs a verbose reboot after updates to ensure the latest kernel is active.
Loop Prevention: Scheduled strictly via Calendar time to prevent reboot loops.

3. Automated LXC Patching
Universal Updater: Detects the OS of every LXC container (Debian, Ubuntu, Alpine, Fedora, Arch, etc.) and runs the appropriate package manager update commands.
Smart State Handling:
Running Containers: Updated live.
Stopped Containers: Temporarily started, updated, and shut down again.
Reboot Audit: Logs which containers require a reboot after patching.

## 🚀 Key Features

* **Unified Management:** Manages both LXC Containers (`pct`) and Virtual Machines (`qm`) from a single JSON state file.
* **Idempotency:** The script runs every 2 minutes. If the environment matches the state file, no action is taken.
* **Drift Detection:** Automatically corrects configuration drift (e.g., RAM, Cores, Hostname) and enforces Power State (Running/Stopped).
* **Foreign Workload Protection:** Scans the host for "Unmanaged" resources. If a Foreign VM/LXC is detected, **deployment is blocked** to prevent accidental overlaps, and a JSON snippet is generated for easy adoption.
* **GitOps Workflow:** The host automatically updates itself from this git repository before every run.

---

** 📅 Automation Schedule
The system runs on three independent Systemd timers to ensure separation of duties:

| **Service** | **Schedule** | **Description** |
| --- | --- | --- |
| **IaC Reconciliation** | **Every 2 Minutes** | Pulls git changes, validates `state.json`, and enforces VM/LXC configuration. |
| **LXC Auto-Update** | **Sundays @ 01:00** | Patches all LXC containers found on the host. |
| **Host Auto-Update** | **Sundays @ 04:00** | Updates Proxmox VE host packages and performs a system reboot. |

---

## 🔄 The Workflow (GitOps)

This solution runs automatically via a Systemd Timer. The execution flow is strictly defined to ensure safety:

1.  **Git Pull & Update:** The wrapper checks this repository for new commits. If a new version exists, it pulls the code and re-runs the installer (`setup.sh`) to update the host logic immediately.
2.  **Dry Run Simulation:** The `proxmox_dsc.sh` engine runs in `--dry-run` mode. It simulates changes without applying them.
3.  **Safety & Audit:**
    * It scans the host for **Foreign Workloads** (VMs not in `state.json`).
    * It checks for **Configuration Errors**.
4.  **Decision Gate:**
    * **⛔ BLOCK:** If *any* Foreign Workloads or Errors are found, the process **aborts**. No changes are made. An alert is logged.
    * **✅ DEPLOY:** If the environment is clean and safe, the script runs in "Live" mode to enforce the `state.json` configuration.
5.  **Post-Run:** Logs are rotated and stored in `/var/log/proxmox_dsc.log`.

---

## 🛠️ Installation

### Prerequisites
* Proxmox VE Host (Debian-based).
* Root access.
* Internet connection (for `apt` and `git`).

### Quick Start
1.  **SSH into your Proxmox Host.**
2.  **Clone this repository:**
    ```bash
    cd /root
    git clone [https://github.com/your-user/proxmox-iac.git](https://github.com/your-user/proxmox-iac.git) iac-repo
    cd iac-repo
    ```
3.  **Run the Setup Script:**
    ```bash
    chmod +x setup.sh
    ./setup.sh
    ```

**That's it.** The `setup.sh` script will:
* Install dependencies (`jq`, `git`).
* Deploy the scripts to `/root/iac/`.
* Configure Log Rotation.
* Install and Start the Systemd Timer (running every 2 minutes).

---

## 📄 Configuration (`state.json`)

Your infrastructure is defined in `state.json`. The script supports two types of resources: `"lxc"` and `"vm"`.

### Example Manifest
```json
[
  {
    "type": "lxc",
    "vmid": 100,
    "hostname": "web-01",
    "template": "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst",
    "memory": 1024,
    "cores": 2,
    "net0": "name=eth0,bridge=vmbr0,ip=dhcp",
    "storage": "local-lvm:8",
    "state": "running"
  },
  {
    "type": "vm",
    "vmid": 200,
    "hostname": "db-01",
    "template": "local:iso/debian-12.0.0-amd64-netinst.iso",
    "memory": 4096,
    "cores": 4,
    "net0": "virtio,bridge=vmbr0",
    "storage": "local-lvm:32",
    "state": "running"
  }
]
```

### Field Reference

| **Field** | **Description** | **LXC Note** | **VM Note** |
| --- | --- | --- | --- |
| `type` | `lxc` or `vm` | Required | Required |
| `vmid` | Unique ID | Proxmox ID | Proxmox ID |
| `hostname` | System Name | Sets hostname | Sets VM Name |
| `template` | Source Image | Path to `.tar.zst` | Path to `.iso` (CDROM) |
| `memory` | RAM in MB | Dynamic | Dynamic |
| `cores` | CPU Cores | Dynamic | Dynamic |
| `storage` | Disk Config | Size in GB (e.g. `local-lvm:8`) | SCSI0 Size (e.g. `local-lvm:32`) |
| `net0` | Network String | e.g. `name=eth0,bridge=vmbr0,ip=dhcp` | e.g. `virtio,bridge=vmbr0` |
| `state` | Power State | `running` or `stopped` | `running` or `stopped` |

* * * * *

🛡️ Handling Foreign Workloads
------------------------------

If you create a VM manually (outside of this repo), the system will enter **Safe Mode**.

1.  The next scheduled run will detect the unmanaged VM ID.

2.  It will log a **WARN** event and **Abort** the deployment to prevent conflict.

3.  **To Fix:** Check the logs for the "Suggested Import" block.

Bash

```
tail -f /var/log/proxmox_dsc.log

```

**Output Example:**

Plaintext

```
[WARN] FOREIGN vm DETECTED: VMID 105
...
--- SUGGESTED JSON IMPORT FOR VM 105 ---
{
  "type": "vm",
  "vmid": 105,
  "hostname": "test-vm",
  ...
}

```

1.  Copy this JSON block into your `state.json`, commit, and push.

2.  The next run will detect the update, recognize the VM, and resume management.

* * * * *

## 📂 Repository Structure
-----------------------

| **File** | **Description** |
| --- | --- |
| `setup.sh` | The installer. Deploys everything. |
| `state.json` | The Infrastructure Manifest. |
| `proxmox_dsc.sh` | The Core IaC Engine (Logic for `pct` and `qm`). |
| `proxmox_autoupdate.sh` | Host OS Update & Reboot script. |
| `proxmox_lxc_autoupdate.sh` | LXC Container Patching script. |

## 📊 Logging & Troubleshooting
----------------------------

All logs are rotated daily and kept for 7 days.

| **Component** | **Log Location** | **Systemd Status** |
| --- | --- | --- |
| **IaC Engine** | `/var/log/proxmox_dsc.log` | `systemctl status proxmox-iac.timer` |
| **Host Update** | `/var/log/proxmox_autoupdate.log` | `systemctl status proxmox-autoupdate.timer` |
| **LXC Update** | `/var/log/proxmox_lxc_autoupdate.log` | `systemctl status proxmox-lxc-autoupdate.timer` |

