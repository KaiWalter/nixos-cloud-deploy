#  get resource IDs by tag
get_resources_by_tag() {
  aws ec2 describe-tags --filters "Name=key,Values=$1" "Name=value,Values=$2" --query "Tags[].[ResourceId]" --output text
}

get_running_instances_by_tag() {
  aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=tag:$1,Values=$2" \
    --query "Reservations[*].Instances[*].InstanceId" --output text
}

define_tag() {
  if [ -z $2 ]; then
    echo "Tags=[{Key=Project,Value=$1}]"
  else
    echo "Tags=[{Key=Project,Value=$1},{Key=Name,Value=$2}]"
  fi
}

# get the latest Nixos AMI ID
# https://nixos.wiki/wiki/Install_NixOS_on_Amazon_EC2
get_latest_nixos_ami() {
    aws ec2 describe-images \
        --owners 427812963091 \
        --filter 'Name=name,Values=nixos/24.05*' \
        --filter 'Name=architecture,Values=x86_64' \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text \
        --region $1
}
