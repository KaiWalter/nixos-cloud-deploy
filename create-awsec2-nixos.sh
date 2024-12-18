#! /bin/sh

set -e

# process command line arguments
VM_NAME=aws-nixos
VM_USERNAME=johndoe
VM_KEYNAME=awsvm
REGION=eu-central-1
GITHUB_SSH_KEY_NAME=github
SIZE="t2.medium"
MODE=image
NIX_CHANNEL=nixos-24.05
NIX_CONFIG_REPO=johndoe/nix-config

VPC_CIDR="10.0.0.0/16"  # VPC CIDR block
SUBNET_CIDR="10.0.1.0/24"  # Subnet CIDR block
DISK_SIZE=1024 # main disk size

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        -u|--user-name)
            VM_USERNAME="$2"
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
        --vpc-name)
            VM_KEYNAME="$2"
            shift 2
            ;;
        --vpc-cidr)
            VPC_CIDR="$2"
            shift 2
            ;;
        --security-group-name)
            SG_NAME="$2"
            shift 2
            ;;
        --acl-name)
            ACL_NAME="$2"
            shift 2
            ;;
        --subnet-cidr)
            SUBNET_CIDR="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --github-key-name)
            GITHUB_SSH_KEY_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# set defaults in case names are not defined
[ -z $SG_NAME] && SG_NAME=$VM_NAME
[ -z $ACL_NAME] && ACL_NAME=$VM_NAME
[ -z $VPCNAME] && VPC_NAME=$VM_NAME
PROJECT_NAME="$VM_NAME"

# obtain sensitive information
. ./common.sh
prepare_keystore
VM_PUB_KEY=$(get_public_key $VM_KEYNAME)

# create EC2 resources
. ./aws-common.sh
echo "Creating resources with tag $(define_tag $PROJECT_NAME)..."

export AWS_PAGER="" 

if ! aws ec2 describe-key-pairs --key-names $VM_KEYNAME --region $REGION &>/dev/null; then
  aws ec2 import-key-pair --key-name $VM_KEYNAME \
    --public-key-material "$(echo $VM_PUB_KEY | base64)" \
    --region $REGION \
    --tag-specifications "ResourceType=key-pair,$(define_tag $PROJECT_NAME $VM_KEYNAME)"
fi

vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" \
  --region $REGION \
  --query "Vpcs[0].VpcId" \
  --output text)
if [ "$vpc_id" == "None" ]; then
  vpc_id=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
    --region $REGION \
    --tag-specifications "ResourceType=vpc,$(define_tag $PROJECT_NAME $VPC_NAME)" \
    --query "Vpc.VpcId" \
    --output text)
  # aws ec2 create-tags --resources $VPC_ID --tags "Key=Name,Value=$VPC_NAME" "Key=Project,Value=$VM_NAME" --region $REGION
  aws ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-hostnames '{"Value":true}'
fi

subnet_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[0].SubnetId" --output text)
if [ "$subnet_id" == "None" ]; then
  subnet_id=$(aws ec2 create-subnet --cidr-block $SUBNET_CIDR \
    --vpc-id $vpc_id \
    --region $REGION \
    --tag-specifications "ResourceType=subnet,$(define_tag $PROJECT_NAME)" \
    --query "Subnet.SubnetId" \
    --output text)
  aws ec2 modify-subnet-attribute --subnet-id $subnet_id --map-public-ip-on-launch
fi

igw_id=$(aws ec2 describe-internet-gateways --filters "Name=tag:Project,Values=$VM_NAME" --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "$igw_id" == "None" ]; then
  igw_id=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,$(define_tag $PROJECT_NAME)" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
  aws ec2 attach-internet-gateway --vpc-id $vpc_id --internet-gateway-id $igw_id
fi

route_table_id=$(aws ec2 describe-route-tables --filters "Name=tag:Project,Values=$VM_NAME" --query "RouteTables[0].RouteTableId" --output text)
if [ "$route_table_id" == "None" ]; then
  route_table_id=$(aws ec2 create-route-table \
    --vpc-id $vpc_id \
    --tag-specifications "ResourceType=route-table,$(define_tag $PROJECT_NAME)" \
    --query 'RouteTable.RouteTableId' \
    --output text)
  aws ec2 create-route --route-table-id $route_table_id --destination-cidr-block 0.0.0.0/0 --gateway-id $igw_id
  aws ec2 associate-route-table --subnet-id $subnet_id --route-table-id $route_table_id
fi

sg_id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$SG_NAME" \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
if [ "$sg_id" == "None" ]; then
  sg_id=$(aws ec2 create-security-group --group-name $SG_NAME \
    --vpc-id $vpc_id \
    --description "$vpc_id $SG_NAME" \
    --region $REGION \
    --tag-specifications "ResourceType=security-group,$(define_tag $PROJECT_NAME $SG_NAME)" \
    --query 'GroupId' \
    --output text)
  aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
fi

acl_id=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Project,Values=$VM_NAME" \
  --region $REGION \
  --query "NetworkAcls[0].NetworkAclId" \
  --output text)
if [ "$acl_id" == "None" ]; then
  acl_id=$(aws ec2 create-network-acl --vpc-id $vpc_id \
    --region $REGION \
    --tag-specifications "ResourceType=network-acl,$(define_tag $PROJECT_NAME $ACL_NAME)" \
    --output text \
    --query 'NetworkAcl.NetworkAclId')
  aws ec2 create-network-acl-entry --network-acl-id $acl_id \
    --rule-number 100 --protocol tcp --port-range From=22,To=22 --cidr-block 0.0.0.0/0 \
    --rule-action allow --ingress
  aws ec2 create-network-acl-entry --network-acl-id $acl_id \
    --rule-number 100 --protocol tcp --port-range From=443,To=443 --cidr-block 0.0.0.0/0 \
    --rule-action allow --egress
  aws ec2 create-network-acl-entry --network-acl-id $acl_id \
    --rule-number 101 --protocol tcp --port-range From=22,To=22 --cidr-block 0.0.0.0/0 \
    --rule-action allow --egress
fi

default_acl_assoc_id=$(aws ec2 describe-network-acls --query "NetworkAcls[0].Associations[?SubnetId=='${subnet_id}'].NetworkAclAssociationId" --output text)
if [ -n "$default_acl_assoc_id" ]; then
  aws ec2 replace-network-acl-association --association-id $default_acl_assoc_id --network-acl-id $acl_id --debug
fi

for instance in $(get_running_instances_by_tag "Project" $VM_NAME | grep "^i-")
do
  instance_id=$instance
done

if [ -z $instance_id ]; then 

  ami_id=$(get_latest_nixos_ami $REGION)

  # Create cloud-init user data
  user_data=$(cat ./nix-config/aws/configuration.nix | sed -e "s|#PLACEHOLDER_PUBKEY|$VM_PUB_KEY|" \
        -e "s|#PLACEHOLDER_USERNAME|$VM_USERNAME|" \
        -e "s|#PLACEHOLDER_HOSTNAME|$VM_NAME|")

  instance_id=$(aws ec2 run-instances \
      --image-id $ami_id \
      --count 1 \
      --instance-type $SIZE \
      --key-name $VM_KEYNAME \
      --subnet-id $subnet_id \
      --security-group-id $sg_id \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$DISK_SIZE}" \
      --user-data "$user_data" \
      --region $REGION \
      --tag-specifications "ResourceType=instance,$(define_tag $PROJECT_NAME $VM_NAME)" \
      --query 'Instances[0].InstanceId' \
      --output text)

  # Wait for the instance to be running and SSH port to be available
  aws ec2 wait instance-running --instance-ids $instance_id --region $REGION
fi

fqdn=$(aws ec2 describe-instances \
    --instance-ids $instance_id \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text \
    --region $REGION)

echo "FQDN: $fqdn"

wait_for_ssh $fqdn root
cleanup_knownhosts $fqdn

# finalize NixOS configuration
ssh-keyscan $fqdn >> ~/.ssh/known_hosts

ssh root@$fqdn 'bash -s' << EOF
while ! grep -q "DO NOT DELETE THIS LINE" /etc/nixos/configuration.nix; do
    echo "Waiting for cloud-init to finish..."
    sleep 1
done

nixos-rebuild switch
reboot &
EOF

echo "Waiting for reboot..."
sleep 5
wait_for_ssh $fqdn $VM_USERNAME

echo "set Nix channel"
ssh $VM_USERNAME@$fqdn "sudo nix-channel --add https://nixos.org/channels/${NIX_CHANNEL} nixos && sudo nix-channel --update"

echo "transfer VM and Git keys..."
ssh $VM_USERNAME@$fqdn "mkdir -p ~/.ssh"
get_private_key "$GITHUB_SSH_KEY_NAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/github'
get_public_key "$GITHUB_SSH_KEY_NAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/github.pub'
get_public_key "$VM_KEYNAME" | ssh $VM_USERNAME@$fqdn -T 'cat > ~/.ssh/awsvm.pub'

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

echo "clone repos and apply final configuration..."
ssh $VM_USERNAME@$fqdn -T "git clone -v git@github.com:$NIX_CONFIG_REPO.git ~/nix-config"
ssh $VM_USERNAME@$fqdn "sudo nixos-rebuild switch --flake ~/nix-config#aws-vm --impure && sudo reboot"

echo "Waiting for reboot..."
sleep 5
wait_for_ssh $fqdn $VM_USERNAME
ssh $VM_USERNAME@$fqdn
