#! /bin/sh

set -e

# process command line arguments
VMNAME=aws-nixos
SGNAME=$VMNAME
VMUSERNAME=johndoe
REGION=eu-central-1
VMKEYNAME=awsvm
GITHUBSSHKEYNAME=github
SIZE="t2.micro"
MODE=image
NIXCHANNEL=nixos-24.05

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--vm-name)
            VMNAME="$2"
            shift 2
            ;;
        -u|--user-name)
            VMUSERNAME="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
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

# create EC2 resources
. ./aws-common.sh
COMMONTAGS="Tags=[{Key=Environment,Value=Demo},{Key=Project,Value=$VMNAME}]"
export AWS_PAGER="" 

if ! aws ec2 describe-key-pairs --key-names $VMKEYNAME --region $REGION &>/dev/null; then
  aws ec2 import-key-pair --key-name $VMKEYNAME \
    --public-key-material "$(echo $VMPUBKEY | base64)" \
    --region $REGION \
    --tag-specifications "ResourceType=key-pair,${COMMONTAGS}"
fi

# Check if security group exists, if not create it
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SGNAME \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
if [ "$SG_ID" == "None" ]; then
    SG_ID=$(aws ec2 create-security-group --group-name $SGNAME \
      --description "Security group for $VMNAME" \
      --region $REGION \
      --tag-specifications "ResourceType=security-group,${COMMONTAGS}" \
      --query 'GroupId' \
      --output text)
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
fi

AMI_ID=$(get_latest_nixos_ami $REGION)

# Create cloud-init user data
USER_DATA=$(cat <<EOF
### https://nixos.org/channels/${NIXCHANNEL} nixos

{ config, pkgs, ... }:
{
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];

  ec2.hvm = true;

  networking.hostName = "${VMNAME}";

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  nix.settings = {
    experimental-features = "nix-command flakes";
  };

  users.users."${VMUSERNAME}" = {
    isNormalUser = true;
    home = "/home/${VMUSERNAME}";
    description = "temporary user to initiate final flake configuration";
    openssh.authorizedKeys.keys = [
        (builtins.readFile /root/.ssh/authorized_keys)
    ];
    extraGroups = ["wheel"];
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;
  services.openssh.permitRootLogin = "prohibit-password";

  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "24.05";
}
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $SIZE \
    --key-name $VMKEYNAME \
    --security-group-ids $SG_ID \
    --user-data "$USER_DATA" \
    --region $REGION \
    --tag-specifications "ResourceType=instance,${COMMONTAGS}" \
    --query 'Instances[0].InstanceId' \
    --output text)

# Wait for the instance to be running and SSH port to be available
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

FQDN=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text \
    --region $REGION)

echo $FQDN

wait_for_ssh $FQDN
cleanup_knownhosts $FQDN

ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' root@$FQDN
