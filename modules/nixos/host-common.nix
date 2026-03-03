# Common host configuration shared between all NixOS machines
{
  config,
  lib,
  inputs,
  pkgs,
  ...
}:
{
  environment.systemPackages = [ pkgs.nmap ];

  boot.loader = {
    systemd-boot.enable = lib.mkDefault true;
    systemd-boot.configurationLimit = lib.mkDefault 5;
    efi.canTouchEfiVariables = lib.mkDefault true;
  };

  # disable ssh askpass
  programs.ssh.askPassword = "";

  services.fwupd.enable = true;

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    flake = "${inputs.self.outPath}#${config.networking.hostName}";
    flags = [
      "--update-input"
      "nixpkgs"
      "-L"
      "--cores 2"
    ];
    # Override in host config: dates = "02:00" or "weekly"
    persistent = true;
  };
}
