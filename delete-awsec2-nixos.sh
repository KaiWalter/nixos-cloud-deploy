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
for instance in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^i-")
do
  echo terminating $instance
  aws ec2 terminate-instances --instance-ids $instance
  aws ec2 wait instance-terminated --instance-ids $instance
done

# Delete Security Groups
for sg in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^sg-")
do
  echo deleting $sg
  aws ec2 delete-security-group --group-id $sg
done

# Delete Subnets
for subnet in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^subnet-")
do
  echo deleting $subnet
  aws ec2 delete-subnet --subnet-id $subnet
done

# Delete ACLs
for acl in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^acl-")
do
  echo deleting $acl
  aws ec2 delete-network-acl --network-acl-id $acl
done

# Delete Routing Tables
for rtb in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^rtb-")
do
  echo deleting $rtb
  aws ec2 delete-route-table --route-table-id $rtb
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
for igw in $(get_resources_by_tag "Project" $PROJECT_NAME | grep "^igw-")
do
  echo deleting $igw
  aws ec2 delete-internet-gateway --internet-gateway-id $igw
done

# Delete Key Pairs
for key in $(aws ec2 describe-key-pairs --query "KeyPairs[?Tags[?Key=='Project' && Value=='$VMNAME']].KeyName" --output text)
do
  echo deleting $key
  aws ec2 delete-key-pair --key-name $key
done

echo "Deletion of tagged resources complete."
