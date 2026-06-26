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

  # Record the flake revision in the deployed system so hosts can report
  # the exact dotflake build with:
  #   nixos-version --configuration-revision
  system.configurationRevision = toString (
    inputs.self.rev or inputs.self.dirtyRev or inputs.self.lastModified or "unknown"
  );

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
