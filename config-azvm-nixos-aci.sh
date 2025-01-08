#! /bin/sh

set -e

# process command line arguments
VM_NAME=az-nixos
VM_USERNAME=johndoe
LOCATION=uksouth
VM_KEYNAME=azvm
SHARE_NAME=nixos-config
CONTAINER_NAME=$VM_NAME
NIX_CHANNEL=nixos-24.05

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        -g|--resource-group)
            RESOURCE_GROUP_NAME="$2"
            shift 2
            ;;
        -u|--user-name)
            VM_USERNAME="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -c|--container-name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --nix-channel)
            NIX_CHANNEL="$2"
            shift 2
            ;;
        --vm-key-name)
            VM_KEYNAME="$2"
            shift 2
            ;;
        -s|--share-name)
            SHARE_NAME="$2"
            ST
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
VM_PRIV_KEY=$(get_private_key $VM_KEYNAME | tr "[:cntrl:]" "|")

# parameters obtain sensitive information
tempnix=$(mktemp -d)
trap 'rm -rf -- "$TEMPNIX"' EXIT
cp -r ./nix-config/az/* $tempnix
sed -e "s|#PLACEHOLDER_PUBKEY|$VM_PUB_KEY|" \
  -e "s|#PLACEHOLDER_USERNAME|$VM_USERNAME|" \
  -e "s|#PLACEHOLDER_HOSTNAME|$VM_NAME|" \
  ./nix-config/az/configuration.nix > $tempnix/configuration.nix

fqdn=$(az vm show --show-details -n $VM_NAME -g $RESOURCE_GROUP_NAME --query fqdns -o tsv | cut -d "," -f 1)
storage_name=$(az storage account list -g $RESOURCE_GROUP_NAME --query "[?kind=='StorageV2']|[0].name" -o tsv)

AZURE_STORAGE_KEY=`az storage account keys list -n $storage_name -g $RESOURCE_GROUP_NAME --query "[0].value" -o tsv`
if [[ $(az storage share exists -n $SHARE_NAME --account-name $storage_name --account-key $AZURE_STORAGE_KEY -o tsv) == "False" ]]; then
  az storage share create -n $SHARE_NAME --account-name $storage_name --account-key $AZURE_STORAGE_KEY
fi

# upload Nix configuration files
for filename in $tempnix/*; do
  echo "uploading ${filename}";
  az storage file upload -s $SHARE_NAME --account-name $storage_name --account-key $AZURE_STORAGE_KEY \
    --source $filename
done

az container create --name $CONTAINER_NAME -g $RESOURCE_GROUP_NAME \
    --image nixpkgs/nix:$NIX_CHANNEL \
    --os-type Linux --cpu 1 --memory 2 \
    --azure-file-volume-account-name $storage_name \
    --azure-file-volume-account-key $AZURE_STORAGE_KEY \
    --azure-file-volume-share-name $SHARE_NAME \
    --azure-file-volume-mount-path "/root/work" \
    --secure-environment-variables NIX_PATH="nixpkgs=channel:$NIX_CHANNEL" FQDN="$fqdn" VMKEY="$VM_PRIV_KEY" \
    --command-line "tail -f /dev/null"

az container exec --name $CONTAINER_NAME -g $RESOURCE_GROUP_NAME --exec-command "sh /root/work/aci-run.sh"

az container stop --name $CONTAINER_NAME -g $RESOURCE_GROUP_NAME
az container delete --name $CONTAINER_NAME -g $RESOURCE_GROUP_NAME -y
az storage share delete -n $SHARE_NAME --account-name $storage_name --account-key $AZURE_STORAGE_KEY
