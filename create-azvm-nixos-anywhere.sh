#! /bin/sh

set -e

# process command line arguments
VM_NAME=az-nixos
VM_USERNAME=johndoe
LOCATION=uksouth
VM_KEYNAME=azvm
GITHUB_KEYNAME=github
SIZE=Standard_B4ms
MODE=aci
IMAGE=Canonical:ubuntu-24_04-lts:server:latest
NIX_CHANNEL=nixos-24.05
NIX_CONFIG_REPO=johndoe/nix-config

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
        -i|--image)
            IMAGE="$2"
            shift 2
            ;;
        -s|--size)
            SIZE="$2"
            shift 2
            ;;
        -m|--mode)
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

[ -z $RESOURCE_GROUP_NAME] && RESOURCE_GROUP_NAME=$VM_NAME

# obtain sensitive information
. ./common.sh
prepare_keystore
VM_PUB_KEY=$(get_public_key $VM_KEYNAME)

# create Azure resources
if ! az group show --name $RESOURCE_GROUP_NAME &> /dev/null; then
  az group create -n $RESOURCE_GROUP_NAME -l $LOCATION
fi

storage_name=$(az storage account list -g $RESOURCE_GROUP_NAME --query "[?kind=='StorageV2']|[0].name" -o tsv)
if [[ -z $storage_name ]]; then
  storage_name=`echo $VM_NAME$RANDOM | tr -cd '[a-z0-9]'`
  az storage account create -n $storage_name -g $RESOURCE_GROUP_NAME \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false
fi

if ! az vm show -n $VM_NAME -g $RESOURCE_GROUP_NAME &> /dev/null; then
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
fqdn=`az vm show --show-details -n $VM_NAME -g $RESOURCE_GROUP_NAME --query fqdns -o tsv | cut -d "," -f 1`

wait_for_ssh $fqdn
cleanup_knownhosts $fqdn

if [[ ! $(ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' $VM_USERNAME@$fqdn uname -a) =~ "NixOS" ]]; then

  echo "configuring root for seamless SSH access"
  ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' $VM_USERNAME@$fqdn sudo cp /home/$VM_USERNAME/.ssh/authorized_keys /root/.ssh/

  echo "test SSH with root"
  ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' root@$fqdn uname -a

  case "$MODE" in
    aci)
      ./config-azvm-nixos-aci.sh --vm-name $VM_NAME \
        --resource-group $RESOURCE_GROUP_NAME \
        --user-name $VM_USERNAME \
        --location $LOCATION \
        --nix-channel $NIX_CHANNEL \
        --vm-key-name $VM_KEYNAME
      ;;
    nixos)
      tempnix=$(mktemp -d)
      trap 'rm -rf -- "$TEMPNIX"' EXIT
      cp -r ./nix-config/az/* $tempnix
      sed -e "s|#PLACEHOLDER_PUBKEY|$VM_PUB_KEY|" \
        -e "s|#PLACEHOLDER_USERNAME|$VM_USERNAME|" \
        -e "s|#PLACEHOLDER_HOSTNAME|$VM_NAME|" \
        ./nix-config/configuration.nix > $tempnix/configuration.nix
        
      nix run github:nix-community/nixos-anywhere -- --flake $tempnix#az-nixos --generate-hardware-config nixos-facter $tempnix/facter.json root@$fqdn
      ;;
    *) echo default
      ;;
  esac

  wait_for_ssh $fqdn
  cleanup_knownhosts $fqdn
fi

# finalize NixOS configuration
ssh-keyscan $fqdn >> ~/.ssh/known_hosts

echo "set Nix channel"
ssh $VM_USERNAME@$fqdn "sudo nix-channel --add https://nixos.org/channels/${NIX_CHANNEL} nixos && sudo nix-channel --update"

echo "transfer VM and Git keys..."
ssh $VM_USERNAME@$fqdn "mkdir -p ~/.ssh"
get_private_key "$GITHUB_KEYNAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/github'
get_public_key "$GITHUB_KEYNAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/github.pub'
get_public_key "$VM_KEYNAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/azvm.pub'

ssh $VM_USERNAME@$fqdn bash -c "'
chmod 700 ~/.ssh
chmod 644 ~/.ssh/*pub
chmod 600 ~/.ssh/github

dos2unix ~/.ssh/github

cat << EOF > ~/.ssh/config
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github

EOF

chmod 644 ~/.ssh/config
ssh-keyscan -H github.com >> ~/.ssh/known_hosts
'"

echo "clone repos (USER)..."
ssh $VM_USERNAME@$fqdn -T "git clone -v git@github.com:$NIX_CONFIG_REPO.git ~/nix-config"
ssh $VM_USERNAME@$fqdn "sudo nixos-rebuild switch --flake ~/nix-config#azvm --impure && sudo reboot"

echo "Waiting for reboot..."
sleep 5
wait_for_ssh $fqdn $VM_USERNAME
ssh $VM_USERNAME@$fqdn
