{
  inputs,
  outputs,
  stateVersion,
  ...
}:
let
  hrosten = import ../../users/hrosten/hrosten.nix;
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ./hardware-configuration.nix
  ]
  ++ (with outputs.nixosModules; [
    common-nix
    host-common
    ssh
    hrosten.nixosModule
  ]);

  networking.hostName = "nocturn";

  # This machine uses BIOS/GRUB, not UEFI/systemd-boot
  boot.loader.systemd-boot.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.grub = {
    enable = true;
    device = "/dev/nvme0n1";
  };

  security.sudo.wheelNeedsPassword = false;

  system.autoUpgrade.dates = "weekly";

  home-manager.extraSpecialArgs = {
    inherit
      inputs
      outputs
      stateVersion
      ;
  };

  home-manager.users.${hrosten.user.username} =
    { ... }:
    {
      imports = [
        ../../users/hrosten/home.nix
      ];
    };
}
