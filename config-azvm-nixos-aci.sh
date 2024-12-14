#! /bin/sh

set -e

# process command line arguments
VMNAME=az-nixos
RESOURCEGROUPNAME=$VMNAME
VMUSERNAME=johndoe
LOCATION=uksouth
VMKEYNAME=azvm
SHARENAME=nixos-config
CONTAINERNAME=$VMNAME
NIXCHANNEL=nixos-24.05

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--vm-name)
            VMNAME="$2"
            shift 2
            ;;
        -g|--resource-group)
            RESOURCEGROUPNAME="$2"
            shift 2
            ;;
        -u|--user-name)
            VMUSERNAME="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -c|--container-name)
            CONTAINERNAME="$2"
            shift 2
            ;;
        --nix-channel)
            NIXCHANNEL="$2"
            shift 2
            ;;
        --vm-key-name)
            VMKEYNAME="$2"
            shift 2
            ;;
        -s|--share-name)
            SHARENAME="$2"
            ST
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# obtain sensitive information
. ./common.sh
prepare_keystore
VMPUBKEY=$(get_public_key $VMKEYNAME)
VMPRIVKEY=$(get_private_key $VMKEYNAME | tr "[:cntrl:]" "|")

# parameters obtain sensitive information
TEMPNIX=$(mktemp -d)
trap 'rm -rf -- "$TEMPNIX"' EXIT
cp -r ./nix-config/* $TEMPNIX
sed -e "s|#PLACEHOLDER_PUBKEY|$VMPUBKEY|" \
  -e "s|#PLACEHOLDER_USERNAME|$VMUSERNAME|" \
  -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|" \
  ./nix-config/configuration.nix > $TEMPNIX/configuration.nix

FQDN=$(az vm show --show-details -n $VMNAME -g $RESOURCEGROUPNAME --query fqdns -o tsv | cut -d "," -f 1)
STORAGENAME=$(az storage account list -g $RESOURCEGROUPNAME --query "[?kind=='StorageV2']|[0].name" -o tsv)

AZURE_STORAGE_KEY=`az storage account keys list -n $STORAGENAME -g $RESOURCEGROUPNAME --query "[0].value" -o tsv`
if [[ $(az storage share exists -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY -o tsv) == "False" ]]; then
  az storage share create -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY
fi

# upload Nix configuration files
for filename in $TEMPNIX/*; do
  echo "uploading ${filename}";
  az storage file upload -s $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY \
    --source $filename
done

az container create --name $CONTAINERNAME -g $RESOURCEGROUPNAME \
    --image nixpkgs/nix:$NIXCHANNEL \
    --os-type Linux --cpu 1 --memory 2 \
    --azure-file-volume-account-name $STORAGENAME \
    --azure-file-volume-account-key $AZURE_STORAGE_KEY \
    --azure-file-volume-share-name $SHARENAME \
    --azure-file-volume-mount-path "/root/work" \
    --secure-environment-variables NIX_PATH="nixpkgs=channel:$NIXCHANNEL" FQDN="$FQDN" VMKEY="$VMPRIVKEY" \
    --command-line "tail -f /dev/null"

az container exec --name $CONTAINERNAME -g $RESOURCEGROUPNAME --exec-command "sh /root/work/aci-run.sh"

az container stop --name $CONTAINERNAME -g $RESOURCEGROUPNAME
az container delete --name $CONTAINERNAME -g $RESOURCEGROUPNAME -y
az storage share delete -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY
