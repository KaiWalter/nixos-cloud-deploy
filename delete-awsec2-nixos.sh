#! /bin/sh

set -ex

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

# delete EC2 resources
. ./aws-common.sh
export AWS_PAGER="" 

# Delete Instances
for instance in $(get_resources_by_tag "Project" $VMNAME | grep "^i-")
do
  echo terminating $instance
  aws ec2 terminate-instances --instance-ids $instance
  aws ec2 wait instance-terminated --instance-ids $instance
done

# Delete Security Groups
for sg in $(get_resources_by_tag "Project" $VMNAME | grep "^sg-")
do
  echo deleting $sg
  aws ec2 delete-security-group --group-id $sg
done

# Delete Subnets
for subnet in $(get_resources_by_tag "Project" $VMNAME | grep "^subnet-")
do
  echo deleting $subnet
  aws ec2 delete-subnet --subnet-id $subnet
done

# Delete VPCs
for vpc in $(get_resources_by_tag "Project" $VMNAME | grep "^vpc-")
do
  echo deleting $vpc
  aws ec2 delete-vpc --vpc-id $vpc
done

# Delete ACLs
for acl in $(get_resources_by_tag "Project" $VMNAME | grep "^acl-")
do
  echo deleting $acl
  aws ec2 delete-network-acl --network-act-id $acl
done

# Delete Key Pairs
for key in $(aws ec2 describe-key-pairs --query "KeyPairs[?Tags[?Key=='Project' && Value=='$VMNAME']].KeyName" --output text)
do
  echo deleting $key
  aws ec2 delete-key-pair --key-name $key
done

echo "Deletion of tagged resources complete."
