#!/bin/bash

# ==============================
# KVM/QEMU VM Backup & Restore Manager
# ==============================

# Debug mode
set -euo pipefail
trap 'echo "Error at line $LINENO"; exit 1' ERR

# User detection
EFFECTIVE_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$EFFECTIVE_USER" | cut -d: -f6)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_dependencies() {
    local missing=()
    
    command -v virsh >/dev/null || missing+=("libvirt-clients")
    command -v xmlstarlet >/dev/null || missing+=("xmlstarlet")
    command -v qemu-img >/dev/null || missing+=("qemu-utils")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}❌ Missing dependencies:${NC}"
        echo "  sudo apt install ${missing[*]}"
        exit 1
    fi
}

backup_vm() {
    echo -e "\n${GREEN}📦 Starting VM Backup${NC}"
    
    # List VMs
    echo -e "${YELLOW}🔍 Available VMs:${NC}"
    virsh list --all --name | grep -v "^$" || {
        echo -e "${RED}❌ No VMs found${NC}"
        return 1
    }

    # Select VM
    read -p "⌨️ Enter VM name: " vmname
    [ -z "$vmname" ] && {
        echo -e "${RED}❌ No VM name provided${NC}"
        return 1
    }

    virsh dominfo "$vmname" >/dev/null 2>&1 || {
        echo -e "${RED}❌ VM '$vmname' not found${NC}"
        return 1
    }

    # Backup location
    default_backup="$USER_HOME/Desktop"
    mkdir -p "$default_backup"
    read -p "💾 Backup location [default: $default_backup]: " backuploc
    backuploc=${backuploc:-"$default_backup"}
    
    mkdir -p "$backuploc" || {
        echo -e "${RED}❌ Cannot create directory${NC}"
        return 1
    }

    # Create backup dir
    timestamp=$(date '+%Y%m%d_%H%M%S')
    backupdir="$backuploc/${vmname}_$timestamp"
    mkdir -p "$backupdir" || {
        echo -e "${RED}❌ Cannot create backup folder${NC}"
        return 1
    }

    # Handle VM state
    state=$(virsh domstate "$vmname")
    if [[ "$state" == "running" ]]; then
        echo -e "${YELLOW}⚠️ Shutting down VM...${NC}"
        virsh shutdown "$vmname"
        for i in {1..30}; do
            [ "$(virsh domstate "$vmname")" != "running" ] && break
            sleep 2
        done
        was_running=true
    fi

    # Backup disks
    echo -e "${YELLOW}🔍 Locating disks...${NC}"
    disk_paths=($(virsh dumpxml "$vmname" | xmlstarlet sel -t -v "//disk[@device='disk']/source/@file" -n 2>/dev/null))
    
    if [ ${#disk_paths[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️ No disks found in VM config${NC}"
    else
        for path in "${disk_paths[@]}"; do
            diskname=$(basename "$path")
            echo -e "💿 Copying: $diskname"
            
            if [ ! -f "$path" ]; then
                echo -e "${YELLOW}⚠️ Disk not found: $path${NC}"
                continue
            fi
            
            if [ -r "$path" ]; then
                cp -av "$path" "$backupdir/" || {
                    echo -e "${YELLOW}⚠️ Retrying with sudo...${NC}"
                    sudo cp -av "$path" "$backupdir/"
                }
            else
                sudo cp -av "$path" "$backupdir/" || {
                    echo -e "${RED}❌ Failed to copy disk${NC}"
                    return 1
                }
            fi
        done
    fi

    # Backup XML
    echo -e "📄 Saving VM config..."
    virsh dumpxml "$vmname" > "$backupdir/$vmname.xml" || {
        echo -e "${RED}❌ Failed to save XML${NC}"
        return 1
    }

    # Fix permissions
    sudo chown -R "$EFFECTIVE_USER:" "$backupdir" 2>/dev/null || true

    # Restart if needed
    [ "${was_running:-false}" == "true" ] && {
        echo -e "🚀 Restarting VM..."
        virsh start "$vmname"
    }

    echo -e "\n${GREEN}✅ Backup complete!${NC}"
    echo "Location: $backupdir"
    ls -lh "$backupdir"
}

restore_vm() {
    echo -e "\n${GREEN}♻️ Starting VM Restore${NC}"
    
    # Find backups
    default_backup="$USER_HOME/Desktop"
    [ -d "$default_backup" ] || mkdir -p "$default_backup"
    
    echo -e "${YELLOW}🔍 Available backups:${NC}"
    find "$default_backup" -maxdepth 2 -name "*.xml" -exec dirname {} \; | sort -u
    
    read -p "⌨️ Enter backup directory: " backupdir
    [ -z "$backupdir" ] && backupdir="$default_backup"
    
    if [ ! -d "$backupdir" ]; then
        echo -e "${RED}❌ Directory not found${NC}"
        return 1
    fi

    # Find XML
    xml_file=$(find "$backupdir" -maxdepth 1 -name "*.xml" | head -1)
    [ -z "$xml_file" ] && {
        echo -e "${RED}❌ No VM config found${NC}"
        return 1
    }

    # New VM name
    read -p "⌨️ Enter new VM name: " new_name
    [ -z "$new_name" ] && {
        echo -e "${RED}❌ Invalid name${NC}"
        return 1
    }

    virsh dominfo "$new_name" >/dev/null 2>&1 && {
        echo -e "${RED}❌ VM '$new_name' already exists${NC}"
        return 1
    }

    # Storage location
    default_storage="$USER_HOME/.local/share/libvirt/images"
    mkdir -p "$default_storage"
    read -p "💾 Disk storage [default: $default_storage]: " storage
    storage=${storage:-"$default_storage"}
    mkdir -p "$storage" || {
        echo -e "${RED}❌ Cannot create storage${NC}"
        return 1
    }

    # Process XML
    tmp_xml=$(mktemp)
    cp "$xml_file" "$tmp_xml"

    # Update identifiers
    xmlstarlet ed -L -u "/domain/name" -v "$new_name" "$tmp_xml"
    xmlstarlet ed -L -u "/domain/uuid" -v "$(uuidgen)" "$tmp_xml"
    xmlstarlet ed -L -d "//interface/mac/@address" "$tmp_xml"

    # Process disks
    disk_paths=($(xmlstarlet sel -t -v "//disk[@device='disk']/source/@file" -n "$tmp_xml"))
    for path in "${disk_paths[@]}"; do
        diskname=$(basename "$path")
        new_disk="$storage/${new_name}_${diskname}"
        
        # Find original disk in backup
        original_disk=$(find "$backupdir" -name "$diskname" | head -1)
        [ -z "$original_disk" ] && {
            echo -e "${YELLOW}⚠️ Disk not found in backup: $diskname${NC}"
            continue
        }

        echo -e "💿 Copying: $diskname → $(basename "$new_disk")"
        cp -av "$original_disk" "$new_disk" || {
            echo -e "${YELLOW}⚠️ Retrying with sudo...${NC}"
            sudo cp -av "$original_disk" "$new_disk"
        }

        # Update XML
        xmlstarlet ed -L -u "//disk/source[@file='$path']/@file" -v "$new_disk" "$tmp_xml"
    done

    # Register VM
    echo -e "📥 Registering VM..."
    virsh define "$tmp_xml" >/dev/null || {
        echo -e "${RED}❌ Failed to register VM${NC}"
        rm -f "$tmp_xml"
        return 1
    }
    rm -f "$tmp_xml"

    # Start option
    read -p "🚀 Start VM now? [y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] && virsh start "$new_name"

    echo -e "\n${GREEN}✅ Restore complete!${NC}"
    echo "VM Name: $new_name"
    echo "Disks: $storage"
}

main_menu() {
    while true; do
        echo -e "\n${GREEN}========================================${NC}"
        echo "🧠 KVM/QEMU VM Backup & Restore Manager"
        echo -e "${GREEN}========================================${NC}"
        echo "1) Backup Virtual Machine"
        echo "2) Restore from Backup"
        echo "3) Exit"
        echo -e "${GREEN}----------------------------------------${NC}"
        
        read -p "⌨️ Select operation [1-3]: " choice
        case $choice in
            1) backup_vm ;;
            2) restore_vm ;;
            3) echo -e "👋 Exiting..."; exit 0 ;;
            *) echo -e "${RED}⚠️ Invalid selection${NC}" ;;
        esac
    done
}

# Main execution
check_dependencies
main_menu
