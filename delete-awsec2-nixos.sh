#! /bin/sh

set -e

# process command line arguments
VMNAME=aws-nixos

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--vm-name)
            VMNAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

PROJECT_NAME="$VMNAME"

# delete EC2 resources
. ./aws-common.sh

export AWS_PAGER="" 

# Delete Instances
for instance_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^i-")
do
  echo terminating $instance_id
  aws ec2 terminate-instances --instance-ids $instance_id
  aws ec2 wait instance-terminated --instance-ids $instance_id
done

# Delete Security Groups
for sg_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^sg-")
do
  echo deleting $sg_id
  aws ec2 delete-security-group --group-id $sg_id
done

# Delete Subnets
for subnet_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^subnet-")
do
  echo deleting $subnet_id
  aws ec2 delete-subnet --subnet-id $subnet_id
done

# Delete ACLs
for acl_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^acl-")
do
  echo deleting $acl_id
  aws ec2 delete-network-acl --network-acl-id $acl_id
done

# Delete Routing Tables
for rtb_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^rtb-")
do
  echo deleting $rtb_id
  aws ec2 delete-route-table --route-table-id $rtb_id
done

# Delete VPCs
for vpc_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^vpc-")
do
  # Detach Internet Gateways
  igw_ids=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$vpc_id" \
    --query 'InternetGateways[*].InternetGatewayId' \
    --output text)
  for igw_id in $igw_ids; do
      echo "Detaching Internet Gateway $igw_id from VPC $vpc_id"
      aws ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id
      if [ $? -eq 0 ]; then
          echo "Successfully detached Internet Gateway $igw_id"
      else
          echo "Failed to detach Internet Gateway $igw_id"
      fi
  done

  echo deleting $vpc_id
  aws ec2 delete-vpc --vpc-id $vpc_id
done

# Delete Internet Gateways
for igw_id in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^igw-")
do
  echo deleting $igw_id
  aws ec2 delete-internet-gateway --internet-gateway-id $igw_id
done

# Delete Key Pairs
for key_name in $(aws ec2 describe-key-pairs --query "KeyPairs[?Tags[?Key=='Project' && Value=='$VMNAME']].KeyName" --output text)
do
  echo deleting $key_name
  aws ec2 delete-key-pair --key-name $key_name
done

echo "Deletion of tagged resources complete."
