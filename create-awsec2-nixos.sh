#! /bin/sh

set -e

# process command line arguments
VMNAME=aws-nixos
VMUSERNAME=johndoe
REGION=eu-central-1
VMKEYNAME=awsvm
GITHUBSSHKEYNAME=github
SIZE="t2.medium"
MODE=image
NIXCHANNEL=nixos-24.05
NIXCONFIGREPO=johndoe/nix-config

VPC_CIDR="10.0.0.0/16"  # VPC CIDR block
SUBNET_CIDR="10.0.1.0/24"  # Subnet CIDR block
DISK_SIZE=1024 # main disk size

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
        --nix-config-repo)
            NIXCONFIGREPO="$2"
            shift 2
            ;;
        --vm-key-name)
            VMKEYNAME="$2"
            shift 2
            ;;
        --vpc-name)
            VMKEYNAME="$2"
            shift 2
            ;;
        --security-group-name)
            SGNAME="$2"
            shift 2
            ;;
        --acl-name)
            ACLNAME="$2"
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

# set defaults in case names are not defined
[ -z $SGNAME] && SGNAME=$VMNAME
[ -z $ACLNAME] && ACLNAME=$VMNAME
[ -z $VPCNAME] && VPCNAME=$VMNAME
PROJECT_NAME="$VMNAME"

# obtain sensitive information
. ./common.sh
prepare_keystore
VMPUBKEY=$(get_public_key $VMKEYNAME)

# create EC2 resources
. ./aws-common.sh

export AWS_PAGER="" 

if ! aws ec2 describe-key-pairs --key-names $VMKEYNAME --region $REGION &>/dev/null; then
  aws ec2 import-key-pair --key-name $VMKEYNAME \
    --public-key-material "$(echo $VMPUBKEY | base64)" \
    --region $REGION \
    --tag-specifications "ResourceType=key-pair,$(define_tag $PROJECT_NAME $VMKEYNAME)"
fi

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPCNAME" \
  --region $REGION \
  --query "Vpcs[0].VpcId" \
  --output text)
if [ "$VPC_ID" == "None" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --query "Vpc.VpcId" --output text)
  aws ec2 create-tags --resources $VPC_ID --tags "Key=Name,Value=$VPCNAME" "Key=Project,Value=$VMNAME" --region $REGION
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
fi

SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[0].SubnetId" --output text)
if [ "$SUBNET_ID" == "None" ]; then
  SUBNET_ID=$(aws ec2 create-subnet --cidr-block $SUBNET_CIDR \
    --vpc-id $VPC_ID \
    --region $REGION \
    --tag-specifications "ResourceType=subnet,$(define_tag $PROJECT_NAME)" \
    --query "Subnet.SubnetId" \
    --output text)
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch
fi

IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=tag:Project,Values=$VMNAME" --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "$IGW_ID" == "None" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,$(define_tag $PROJECT_NAME)" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
  aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
fi

ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=tag:Project,Values=$VMNAME" --query "RouteTables[0].RouteTableId" --output text)
if [ "$ROUTE_TABLE_ID" == "None" ]; then
  ROUTE_TABLE_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,$(define_tag $PROJECT_NAME)" \
    --query 'RouteTable.RouteTableId' \
    --output text)
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID
fi

SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SGNAME" \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
if [ "$SG_ID" == "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name $SGNAME \
    --vpc-id $VPC_ID \
    --description "$VPC_ID $SGNAME" \
    --region $REGION \
    --tag-specifications "ResourceType=security-group,$(define_tag $PROJECT_NAME $SGNAME)" \
    --query 'GroupId' \
    --output text)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
fi

ACL_ID=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$VMNAME" \
  --region $REGION \
  --query "NetworkAcls[0].NetworkAclId" \
  --output text)
if [ "$ACL_ID" == "None" ]; then
  ACL_ID=$(aws ec2 create-network-acl --vpc-id $VPC_ID \
    --region $REGION \
    --tag-specifications "ResourceType=network-acl,$(define_tag $PROJECT_NAME $ACLNAME)" \
    --output text \
    --query 'NetworkAcl.NetworkAclId')
  aws ec2 create-network-acl-entry --network-acl-id $ACL_ID \
    --rule-number 100 --protocol tcp --port-range From=22,To=22 --cidr-block 0.0.0.0/0 \
    --rule-action allow --ingress
  aws ec2 create-network-acl-entry --network-acl-id $ACL_ID \
    --rule-number 100 --protocol tcp --port-range From=443,To=443 --cidr-block 0.0.0.0/0 \
    --rule-action allow --egress
  aws ec2 create-network-acl-entry --network-acl-id $ACL_ID \
    --rule-number 101 --protocol tcp --port-range From=22,To=22 --cidr-block 0.0.0.0/0 \
    --rule-action allow --egress
fi

DEFAULT_ACL_ASSOCIATION_ID=$(aws ec2 describe-network-acls --query "NetworkAcls[0].Associations[?SubnetId=='${SUBNET_ID}'].NetworkAclAssociationId" --output text)
if [ -n "$DEFAULT_ACL_ASSOCIATION_ID" ]; then
  aws ec2 replace-network-acl-association --association-id $DEFAULT_ACL_ASSOCIATION_ID --network-acl-id $ACL_ID --debug
fi

for instance in $(get_running_instances_by_tag "Project" $VMNAME | grep "^i-")
do
  INSTANCE_ID=$instance
done

if [ -z $INSTANCE_ID ]; then 

  AMI_ID=$(get_latest_nixos_ami $REGION)

  # Create cloud-init user data
  USER_DATA=$(cat ./nix-config/aws/configuration.nix | sed -e "s|#PLACEHOLDER_PUBKEY|$VMPUBKEY|" \
        -e "s|#PLACEHOLDER_USERNAME|$VMUSERNAME|" \
        -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|")

  INSTANCE_ID=$(aws ec2 run-instances \
      --image-id $AMI_ID \
      --count 1 \
      --instance-type $SIZE \
      --key-name $VMKEYNAME \
      --subnet-id $SUBNET_ID \
      --security-group-id $SG_ID \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$DISK_SIZE}" \
      --user-data "$USER_DATA" \
      --region $REGION \
      --tag-specifications "ResourceType=instance,$(define_tag $PROJECT_NAME $VMNAME)" \
      --query 'Instances[0].InstanceId' \
      --output text)

  # Wait for the instance to be running and SSH port to be available
  aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION
fi

FQDN=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text \
    --region $REGION)

echo "FQDN: $FQDN"

wait_for_ssh $FQDN root
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
wait_for_ssh $FQDN $VMUSERNAME

echo "set Nix channel"
ssh $VMUSERNAME@$FQDN "sudo nix-channel --add https://nixos.org/channels/${NIXCHANNEL} nixos && sudo nix-channel --update"

echo "transfer VM and Git keys..."
ssh $VMUSERNAME@$FQDN "mkdir -p ~/.ssh"
get_private_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github'
get_public_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github.pub'
get_public_key "$VMKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/awsvm.pub'

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

echo "clone repos and apply final configuration..."
ssh $VMUSERNAME@$FQDN -T "git clone -v git@github.com:$NIXCONFIGREPO.git ~/nix-config"
ssh $VMUSERNAME@$FQDN "sudo nixos-rebuild switch --flake ~/nix-config#aws-vm --impure && sudo reboot"

echo "Waiting for reboot..."
sleep 5
wait_for_ssh $FQDN $VMUSERNAME
ssh $VMUSERNAME@$FQDN
