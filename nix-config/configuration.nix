{
  modulesPath,
  lib,
  pkgs,
  ...
}: let
  username = "#PLACEHOLDER_USERNAME";
  hostname = "#PLACEHOLDER_HOSTNAME";
  pubkey = "#PLACEHOLDER_PUBKEY";
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  networking.hostName = hostname;

  services.openssh = {
    enable = lib.mkForce true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  environment.systemPackages = with pkgs; [
    curl
    dos2unix
    git
    vim
  ];

  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
  };

  users.users."${username}" = {
    isNormalUser = true;
    home = "/home/${username}";
    description = "";
    openssh.authorizedKeys.keys = [
      pubkey
    ];
    extraGroups = ["wheel"];
  };

  security.sudo.extraRules = [
    {
      users = [username];
      commands = [
        {
          command = "ALL";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  system.stateVersion = "24.05";
}
