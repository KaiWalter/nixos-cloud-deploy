#!/bin/sh

set -e

echo "configure Nix..."
mkdir -p /etc/nix
cat << EOF >/etc/nix/nix.conf
experimental-features = nix-command flakes
warn-dirty = false
EOF

echo "initialize Nix configuration files..."
mkdir -p /root/nix-config
cp -v /root/work/*nix /root/nix-config/

git config --global init.defaultBranch main
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"

cd /root/nix-config
git init
git add .
git commit -m "WIP"
nix flake show

echo "set SSH private key to VM..."
mkdir -p /root/.ssh
KEYFILE=/root/.ssh/vmkey
echo $VMKEY | tr "|" "\n" >$KEYFILE
chmod 0600 $KEYFILE

nix run github:nix-community/nixos-anywhere -- --flake /root/nix-config#az-nixos --generate-hardware-config nixos-facter /root/nix-config/facter.json -i $KEYFILE root@$FQDN
