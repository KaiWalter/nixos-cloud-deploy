export DEBIAN_FRONTEND=noninteractive
# Channel & config path we want the infect script (running as root) to see
NIX_CHANNEL=${NIX_CHANNEL:-nixos-25.05}
NIXOS_CONFIG=${NIXOS_CONFIG:-/home/$USER/nixos-azure-config.nix}
export NIX_CHANNEL NIXOS_CONFIG

# Generate the NixOS configuration file (no sudo needed; root can read later)
cat > "$NIXOS_CONFIG" <<'EOF'
{ config, pkgs, lib, ... }:
let
  # Set these three to the actual values (no braces) before running infect
  ROOT_UUID = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
  BOOT_UUID = "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy";
  EFI_UUID  = "ZZZZ-YYYY";
  vmName = "AABBCCDD-VM";
  vmUser = "AABBCCDD-USER";
in
{
  ############################
  # Core system + versioning #
  ############################
  system.stateVersion = "25.05";  # match your chosen channel
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  ################
  # Boot / Disks #
  ################
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    devices = [ "nodev" ];
    efiInstallAsRemovable = true;     # no EFI vars on Azure
    copyKernels = true;
    # Auto-boot directly into the default NixOS generation (no menu pause)
    default = 0;
    timeout = 0;  # set to >0 (e.g. 5) if you want a visible menu
  };
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;

  # Helpful for serial console diagnostics on Azure
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "earlyprintk=ttyS0"
    "rootdelay=10"
  ];

  # Ensure Azure / Hyper-V storage & net drivers appear early
  boot.initrd.availableKernelModules = [
    "hv_vmbus" "hv_storvsc" "hv_netvsc"
    "sd_mod" "sr_mod" "ext4"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/${ROOT_UUID}";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/${BOOT_UUID}";
    fsType = "ext4";
  };

  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/${EFI_UUID}";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Disable swap (infect script usually removes it anyway)
  swapDevices = [ ];

  ################################
  # Azure / cloud specific bits  #
  ################################
  # Azure Linux Agent (WALinuxAgent)
  services.waagent = {
    enable = true;
    # 'provisionUser' is not a valid option; instead explicitly disable
    # waagent provisioning so our declarative user remains untouched.
    settings = {
      Provisioning.Enabled = "n"; # don't let waagent manage users
    };
  };

  # Optional: if you want cloud-init disabled (Ubuntu used it)
  services.cloud-init.enable = false;

  # Networking (simple DHCP on first interface)
  networking = {
    hostName = vmName;
    usePredictableInterfaceNames = false;  # matches eth0 style
    useDHCP = lib.mkDefault true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  ################
  # SSH / Access #
  ################
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users."${vmUser}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keyFiles = [ "/home/${vmUser}/.ssh/authorized_keys" ];
  };

  security.sudo.wheelNeedsPassword = false;

  #####################
  # Time & basic pkgs #
  #####################
  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [
    git curl htop jq bashInteractive vim
  ];

  #########################
  # Minimal hardening etc #
  #########################
  services.journald.extraConfig = "SystemMaxUse=1G";
  systemd.services."serial-getty@ttyS0".enable = true;

  # Keep some generations but prune aggressively
  boot.loader.grub.configurationLimit = 8;
}
EOF

ROOT_UUID=$(blkid -s UUID -o value /dev/sda1)
BOOT_UUID=$(blkid -s UUID -o value /dev/sda16)
EFI_UUID=$(blkid -s UUID -o value /dev/sda15)
echo "Root=$ROOT_UUID  Boot=$BOOT_UUID  EFI=$EFI_UUID"

sed -i "s|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx|$ROOT_UUID|" "$NIXOS_CONFIG"
sed -i "s|yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy|$BOOT_UUID|" "$NIXOS_CONFIG"
sed -i "s|ZZZZ-YYYY|$EFI_UUID|" "$NIXOS_CONFIG"
sed -i "s|AABBCCDD-VM|$(hostname)|" "$NIXOS_CONFIG"
sed -i "s|AABBCCDD-USER|$USER|" "$NIXOS_CONFIG"

echo "Prepared $NIXOS_CONFIG; launching infect with NIX_CHANNEL=$NIX_CHANNEL" >&2

# Run infect ensuring the variables are passed to root. Avoid process substitution with sudo
# (which caused /dev/fd/63: No such file or directory). Use a temp file instead.
INFECT_TMP=$(mktemp /tmp/nixos-infect.XXXXXX)
if curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect -o "$INFECT_TMP"; then
  sudo env NIX_CHANNEL="$NIX_CHANNEL" NIXOS_CONFIG="$NIXOS_CONFIG" \
    bash -x "$INFECT_TMP"
  rm -f "$INFECT_TMP"
else
  echo "Failed to download nixos-infect script" >&2
  rm -f "$INFECT_TMP"
  exit 1
fi

echo "Infect script finished. If successful, the system will reboot shortly." >&2
