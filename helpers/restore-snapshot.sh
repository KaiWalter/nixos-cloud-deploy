#! /usr/bin/env bash

set -e

# process command line arguments
VM_NAME=az-nixos

while [[ $# -gt 0 ]]; do
  case $1 in
  -n | --vm-name)
    VM_NAME="$2"
    shift 2
    ;;
  -g | --resource-group)
    RESOURCE_GROUP_NAME="$2"
    shift 2
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

[ -z $RESOURCE_GROUP_NAME ] && RESOURCE_GROUP_NAME=$VM_NAME

SNAP=osdisk-snap
NEWDISK=osdisk-from-snap

az vm deallocate -g $RESOURCE_GROUP_NAME -n $VM_NAME
# If a previous run left a disk with the target name, remove it (only if detached)
if az disk show -g $RESOURCE_GROUP_NAME -n $NEWDISK &>/dev/null; then
  attached_vm=$(az disk show -g $RESOURCE_GROUP_NAME -n $NEWDISK --query managedBy -o tsv)
  if [[ -n $attached_vm ]]; then
    target_vm_id=$(az vm show -g $RESOURCE_GROUP_NAME -n $VM_NAME --query id -o tsv)
    osdisk_name=$(az vm show -g $RESOURCE_GROUP_NAME -n $VM_NAME --query 'storageProfile.osDisk.name' -o tsv)
    if [[ $attached_vm == $target_vm_id ]]; then
      if [[ $osdisk_name == $NEWDISK ]]; then
        # It's currently the OS disk of the target VM; we cannot detach it. Pick a new name.
        ts=$(date +%s)
        echo "Existing disk '$NEWDISK' is the current OS disk of VM '$VM_NAME'. Using a new disk name with timestamp: ${NEWDISK}-${ts}" >&2
        NEWDISK="${NEWDISK}-${ts}"
      else
        # It's a data disk on the target VM; detach automatically.
        echo "Detaching data disk '$NEWDISK' from VM '$VM_NAME'" >&2
        az vm disk detach -g $RESOURCE_GROUP_NAME --vm-name $VM_NAME --name $NEWDISK
        echo "Deleting detached disk '$NEWDISK'" >&2
        az disk delete -g $RESOURCE_GROUP_NAME -n $NEWDISK -y
      fi
    else
      echo "Disk '$NEWDISK' is attached to a different VM ($attached_vm). Aborting to avoid unintended detach." >&2
      exit 1
    fi
  else
    echo "Deleting existing unattached disk '$NEWDISK' in resource group '$RESOURCE_GROUP_NAME'" >&2
    az disk delete -g $RESOURCE_GROUP_NAME -n $NEWDISK -y
  fi
fi
az disk create -g $RESOURCE_GROUP_NAME -n $NEWDISK --source $SNAP
az vm update -g $RESOURCE_GROUP_NAME -n $VM_NAME --os-disk $(az disk show -g $RESOURCE_GROUP_NAME -n $NEWDISK --query id -o tsv)
az vm start -g $RESOURCE_GROUP_NAME -n $VM_NAME
