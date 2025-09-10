#! /usr/bin/env bash

# disk configuration after Ubuntu install:
# $lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
# NAME     SIZE TYPE MOUNTPOIN LABEL
# sda        1T disk
# ├─sda1  1023G part /         cloudimg-rootfs
# ├─sda14    4M part
# ├─sda15  106M part /boot/efi UEFI
# └─sda16  913M part /boot     BOOT
# sdb       32G disk
# └─sdb1    32G part /mnt


set -e

# process command line arguments
VM_NAME=az-nixos
VM_USERNAME=johndoe
LOCATION=uksouth
VM_KEYNAME=azvm
GITHUB_KEYNAME=github
SIZE=Standard_B4ms
MODE=aci
IMAGE=Canonical:ubuntu-24_04-lts:server:latest # or ARM64: Canonical:ubuntu-24_04-lts:server-arm64:latest
NIX_CHANNEL=nixos-25.05
NIX_CONFIG_REPO=johndoe/nix-config

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
  -u | --user-name)
    VM_USERNAME="$2"
    shift 2
    ;;
  -l | --location)
    LOCATION="$2"
    shift 2
    ;;
  -i | --image)
    IMAGE="$2"
    shift 2
    ;;
  -s | --size)
    SIZE="$2"
    shift 2
    ;;
  -m | --mode)
    MODE="$2"
    shift 2
    ;;
  --nix-channel)
    NIX_CHANNEL="$2"
    shift 2
    ;;
  --nix-config-repo)
    NIX_CONFIG_REPO="$2"
    shift 2
    ;;
  --vm-key-name)
    VM_KEYNAME="$2"
    shift 2
    ;;
  --github-key-name)
    GITHUB_KEYNAME="$2"
    shift 2
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

[ -z $RESOURCE_GROUP_NAME ] && RESOURCE_GROUP_NAME=$VM_NAME

# obtain sensitive information
. ./common.sh
prepare_keystore
VM_PUB_KEY=$(get_public_key $VM_KEYNAME)

# create Azure resources
if ! az group show --name $RESOURCE_GROUP_NAME &>/dev/null; then
  az group create -n $RESOURCE_GROUP_NAME -l $LOCATION
fi

storage_name=$(az storage account list -g $RESOURCE_GROUP_NAME --query "[?kind=='StorageV2']|[0].name" -o tsv)
if [[ -z $storage_name ]]; then
  storage_name=$(echo $VM_NAME$RANDOM | tr -cd '[a-z0-9]')
  az storage account create -n $storage_name -g $RESOURCE_GROUP_NAME \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false
fi

if ! az vm show -n $VM_NAME -g $RESOURCE_GROUP_NAME &>/dev/null; then
  az vm create -n $VM_NAME -g $RESOURCE_GROUP_NAME \
    --image "$IMAGE" \
    --public-ip-sku Standard \
    --public-ip-address-dns-name $VM_NAME \
    --ssh-key-values "$VM_PUB_KEY" \
    --admin-username $VM_USERNAME \
    --os-disk-size-gb 1024 \
    --boot-diagnostics-storage $storage_name \
    --size $SIZE \
    --security-type Standard

  az vm auto-shutdown -n $VM_NAME -g $RESOURCE_GROUP_NAME \
    --time "22:00"
fi

# inject Nixos
fqdn=$(az vm show --show-details -n $VM_NAME -g $RESOURCE_GROUP_NAME --query fqdns -o tsv | cut -d "," -f 1)

wait_for_ssh $fqdn
cleanup_knownhosts $fqdn

ssh $VM_USERNAME@$fqdn
