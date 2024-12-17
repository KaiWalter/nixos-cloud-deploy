# DO NOT DELETE THIS LINE
{ modulesPath, pkgs, ... }: let
  username = "#PLACEHOLDER_USERNAME";
  hostname = "#PLACEHOLDER_HOSTNAME";
  pubkey = "#PLACEHOLDER_PUBKEY";
in {
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  systemd.services.amazon-init.enable = false;

  networking.hostName = hostname;

  environment.systemPackages = with pkgs; [
    curl
    dos2unix
    git
    vim
  ];

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

   system.stateVersion = "24.11";
}
