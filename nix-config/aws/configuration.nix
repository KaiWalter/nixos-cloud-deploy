# DO NOT DELETE THIS LINE
{ modulesPath, pkgs, ... }: {
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
  systemd.services.amazon-init.enable = false;

  networking.hostName = "#PLACEHOLDER_HOSTNAME";

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  system.stateVersion = "24.11";
}

