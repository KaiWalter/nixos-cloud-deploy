# Deploy cloud VMs with NixOS

## Azure VM with nixos-anywhere

Repository referenced and the process is described in [this post](https://community.ops.io/kaiwalter/inject-nixos-into-an-azure-vm-with-nixos-anywhere-and-azure-container-intances-4ke6).

Script `create-azvm-nixos-anywhere.sh` drives the whole VM creation process. All general parameters to control the process, can be overwritten by command line arguments.

| argument                                       | command line argument(s) | purpose                                                                                                                |
| ---------------------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| VMNAME=az-nixos                                | -n --vm-name             | sets the name of the VM                                                                                                |
| RESOURCEGROUPNAME=$VMNAME                      | -g --resource-group      | controls the Azure resource group to create and use                                                                    |
| VMUSERNAME=johndoe                             | -u --user-name           | sets the user name (additional to root) to setup on the VM                                                             |
| LOCATION=uksouth                               | -l --location            | controls the Azure region to be used                                                                                   |
| VMKEYNAME=azvm                                 | --vm-key-name            | controls the name of the SSH public key to be used on the VM                                                           |
| GITHUBSSHKEYNAME=github                        | --github-key-name        | controls the name of the GitHub SSH keys to be used to pull the desired Nix configuration repository                   |
| SIZE=Standard_B4ms                             | -s --size                | controls the Azure VM SKU                                                                                              |
| MODE=aci                                       | -m --mode                | controls the source system mode: `aci` using ACI, `nixos` assuming to use the local Nix(OS) configuration              |
| IMAGE=Canonical:ubuntu-24_04-lts:server:latest | -i --image               | controls the initial Azure VM image to be used on the target system to inject NixOS into;<BR/>needs to support `kexec` |
| NIXCHANNEL=nixos-24.05                         | --nix-channel            | controls the NixOS channel to be used for injection and installation                                                   |

Script `config-azvm-nixos-anywhere.sh` is called by the creation script above to bring up an Azure Container Instance with NixOS to drive the injection process. This script could be used standalone on an existing Azure VM.

| argument                  | command line argument(s) | purpose                                                                    |
| ------------------------- | ------------------------ | -------------------------------------------------------------------------- |
| VMNAME=az-nixos           | -n --vm-name             | specifies the name of the VM                                               |
| RESOURCEGROUPNAME=$VMNAME | -g --resource-group      | specifies the Azure resource group to use                                  |
| VMUSERNAME=johndoe        | -u --user-name           | specifies the user name                                                    |
| LOCATION=uksouth          | -l --location            | specifies he Azure region to be used                                       |
| VMKEYNAME=azvm            | --vm-key-name            | specifies the name of the SSH public key to be used on the VM              |
| SHARENAME=nixos-config    | -s --share-name          | specifies the Azure file share name to be used to hold configuration files |
| CONTAINERNAME=$VMNAME     | -c --container-name      | specifies the ACI container name to be used                                |
| NIXCHANNEL=nixos-24.05    | --nix-channel            | controls the NixOS channel to be used for injection and installation       |

## AWS EC2 with AMI image

Script `create-awsec2-nixos.sh` drives the whole VM creation process. All general parameters to control the process, can be overwritten by command line arguments. All resources are tagged with key `Project` and value `_name_of_the_VM_`.

| argument                           | command line argument(s) | purpose                                                                                              |
| ---------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| VM_NAME=aws-nixos                  | -n --vm-name             | sets the name of the VM/EC2 instance                                                                 |
| VM_USERNAME=johndoe                | -u --user-name           | sets the user name (additional to root) to setup on the VM                                           |
| REGION=eu-central-1                | -r --region              | controls the AWS region to be used                                                                   |
| VM_KEYNAME=awsvm                   | --vm-key-name            | controls the name of the SSH public key to be used on the VM                                         |
| GITHUB_SSH_KEY_NAME=github         | --github-key-name        | controls the name of the GitHub SSH keys to be used to pull the desired Nix configuration repository |
| SIZE=t2.medium                     | -s --size                | controls the AWS EC2 instance type                                                                   |
| MODE=image                         | -m --mode                | controls the source system mode: `image` using available AMI image                                   |
| DISK_SIZE=1024                     | --disk-size              | controls the initial root volume size                                                                |
| NIX_CHANNEL=nixos-24.05            | --nix-channel            | controls the NixOS channel to be used for injection and installation                                 |
| NIX_CONFIG_REPO=johndoe/nix-config | --nix-config-repo        | controls the Nix configuration repo to be cloned and switched to when finalizing the installation    |
| ACL_NAME=$VM_NAME                  | --acl-name               | controls the name of the ACL                                                                         |
| SG_NAME=$VM_NAME                   | --security-group-name    | controls the name of the security group                                                              |
| SUBNET_CIDR="10.0.1.0/24"          | --subnet-cidr            | controls the subnet CIDR range                                                                       |
| VPC_CIDR="10.0.0.0/16"             | --vpc-cidr               | controls the VPC CIDR range                                                                          |
| VPC_NAME=$VM_NAME                  | --vpc-name               | controls the name of the VPC                                                                         |

Script `delete-awsec2-nixos.sh` deletes all resources created with above script.

| argument          | command line argument(s) | purpose                              |
| ----------------- | ------------------------ | ------------------------------------ |
| VM_NAME=aws-nixos | -n --vm-name             | sets the name of the VM/EC2 instance |
