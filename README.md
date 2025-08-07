# KVM Backup Manager

A script for automating full VM backups and restores using KVM/QEMU on Linux.

---

## ✨ Features

- **Intuitive Menu Interface** – Easy-to-follow prompts  
- **Complete VM Backups** – Captures both disk images and XML configurations  
- **Flexible Restore** – Restore VMs with new names and storage locations  
- **State Handling** – Automatically pauses/resumes running VMs during backup  
- **Permission Management** – Handles both user and root-owned resources  

---

## 📋 Requirements

- **KVM/QEMU** virtualization environment

### Dependencies:

```bash
sudo apt install libvirt-clients xmlstarlet qemu-utils
🚀 Usage
Make the script executable:

bash
chmod +x kvm-backup-manager.sh
Run as regular user:

bash
./kvm-backup-manager.sh
(The script will automatically request sudo when needed)
```
### 📦 Backup Workflow (Option 1)
- ** Select VM from list
- ** Choose backup location (default: ~/Desktop)
- ** Script handles: shutdown → copy → startup
- ** Backup includes:
- ** VM disk images
- ** XML configuration file
- ** Timestamped directory

### ♻️ Restore Workflow (Option 2)
- ** Select backup directory
- ** Provide new VM name
- ** Specify disk storage location
- ** Script performs:
- ** Generates new UUID
- ** Creates MAC-free network config
- ** Copies disks to new location
- ** Registers VM with libvirt

### ⚠️ Important Notes
- ** Disk Permissions:
- ** Backups may require sudo for disk access
- ** Restored disks will be owned by the current user

### VM State:
- ** Running VMs are gracefully shut down during backup
- ** Original state is restored after backup completes

### Storage:
- ** Default backup location: ~/Desktop
- ** Default disk storage: ~/.local/share/libvirt/images
### 🤝 Contribution
- ** Pull requests and issues welcome! Please ensure:
- ** Compatibility with standard KVM setups
- ** Script remains lightweight
- ** Error handling is preserved
