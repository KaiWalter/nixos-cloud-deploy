#! /bin/sh

set -e

# process command line arguments
VMNAME=az-nixos
RESOURCEGROUPNAME=$VMNAME
VMUSERNAME=johndoe
LOCATION=uksouth
VMKEYNAME=azvm
GITHUBSSHKEYNAME=github
SIZE=Standard_B4ms
MODE=aci
IMAGE=Canonical:ubuntu-24_04-lts:server:latest
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
            NIXCHANNEL="$2"
            shift 2
            ;;
        --vm-key-name)
            VMKEYNAME="$2"
            shift 2
            ;;
        --github-key-name)
            GITHUBSSHKEYNAME="$2"
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

# create Azure resources
if ! az group show --name $RESOURCEGROUPNAME &> /dev/null; then
  az group create -n $RESOURCEGROUPNAME -l $LOCATION
fi

STORAGENAME=$(az storage account list -g $RESOURCEGROUPNAME --query "[?kind=='StorageV2']|[0].name" -o tsv)
if [[ -z $STORAGENAME ]]; then
  STORAGENAME=`echo $VMNAME$RANDOM | tr -cd '[a-z0-9]'`
  az storage account create -n $STORAGENAME -g $RESOURCEGROUPNAME \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false
fi

if ! az vm show -n $VMNAME -g $RESOURCEGROUPNAME &> /dev/null; then
  az vm create -n $VMNAME -g $RESOURCEGROUPNAME \
    --image "$IMAGE" \
    --public-ip-sku Standard \
    --public-ip-address-dns-name $VMNAME \
    --ssh-key-values "$VMPUBKEY" \
    --admin-username $VMUSERNAME \
    --os-disk-size-gb 1024 \
    --boot-diagnostics-storage $STORAGENAME \
    --size $SIZE \
    --security-type Standard

  az vm auto-shutdown -n $VMNAME -g $RESOURCEGROUPNAME \
    --time "22:00"
fi

# inject Nixos
FQDN=`az vm show --show-details -n $VMNAME -g $RESOURCEGROUPNAME --query fqdns -o tsv | cut -d "," -f 1`

wait_for_ssh $FQDN
cleanup_knownhosts $FQDN

if [[ ! $(ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' $VMUSERNAME@$FQDN uname -a) =~ "NixOS" ]]; then

  echo "configuring root for seamless SSH access"
  ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' $VMUSERNAME@$FQDN sudo cp /home/$VMUSERNAME/.ssh/authorized_keys /root/.ssh/

  echo "test SSH with root"
  ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' root@$FQDN uname -a

  case "$MODE" in
    aci)
      ./config-azvm-nixos-aci.sh --vm-name $VMNAME \
        --resource-group $RESOURCEGROUPNAME \
        --user-name $VMUSERNAME \
        --location $LOCATION \
        --nix-channel $NIXCHANNEL \
        --vm-key-name $VMKEYNAME
      ;;
    nixos)
      TEMPNIX=$(mktemp -d)
      trap 'rm -rf -- "$TEMPNIX"' EXIT
      cp -r ./nix-config/az/* $TEMPNIX
      sed -e "s|#PLACEHOLDER_PUBKEY|$VMPUBKEY|" \
        -e "s|#PLACEHOLDER_USERNAME|$VMUSERNAME|" \
        -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|" \
        ./nix-config/configuration.nix > $TEMPNIX/configuration.nix
        
      nix run github:nix-community/nixos-anywhere -- --flake $TEMPNIX#az-nixos --generate-hardware-config nixos-facter $TEMPNIX/facter.json root@$FQDN
      ;;
    *) echo default
      ;;
  esac

  wait_for_ssh $FQDN
  cleanup_knownhosts $FQDN
fi

# finalize NixOS configuration
ssh-keyscan $FQDN >> ~/.ssh/known_hosts

echo "set Nix channel"
ssh $VMUSERNAME@$FQDN "sudo nix-channel --add https://nixos.org/channels/${NIXCHANNEL} nixos && sudo nix-channel --update"

echo "transfer VM and Git keys..."
ssh $VMUSERNAME@$FQDN "mkdir -p ~/.ssh"
get_private_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github'
get_public_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github.pub'
get_public_key "$VMKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/azvm.pub'

ssh $VMUSERNAME@$FQDN bash -c "'
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
ssh $VMUSERNAME@$FQDN -T "git clone -v git@github.com:johndoe/nix-config.git ~/nix-config"
ssh $VMUSERNAME@$FQDN -T "sudo nixos-rebuild switch --flake ~/nix-config#az-vm --impure"
