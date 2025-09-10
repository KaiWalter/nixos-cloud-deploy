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

az vm deallocate -g $RESOURCE_GROUP_NAME -n $VM_NAME
OSDISK_ID=$(az vm show -g $RESOURCE_GROUP_NAME -n $VM_NAME --query "storageProfile.osDisk.managedDisk.id" -o tsv)
az snapshot create -g $RESOURCE_GROUP_NAME -n $SNAP --source $OSDISK_ID
az vm start -g $RESOURCE_GROUP_NAME -n $VM_NAME
