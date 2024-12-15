#! /bin/sh

set -e

# process command line arguments
VMNAME=aws-nixos
SGNAME=$VMNAME
VMUSERNAME=johndoe
REGION=eu-central-1
VMKEYNAME=awsvm
GITHUBSSHKEYNAME=github
SIZE="t2.medium"
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
USER_DATA=$(cat ./nix-config/aws/configuration.nix | sed -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|")

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

wait_for_ssh $FQDN
cleanup_knownhosts $FQDN

# finalize NixOS configuration
ssh-keyscan $FQDN >> ~/.ssh/known_hosts

ssh root@$FQDN 'bash -s' << EOF
while ! grep -q "DO NOT DELETE THIS LINE" /etc/nixos/configuration.nix; do
    echo "Waiting for cloud-init to finish..."
    sleep 1
done

nixos-rebuild switch
reboot &
EOF

echo "Waiting for reboot..."
sleep 5
wait_for_ssh $FQDN
ssh root@$FQDN
