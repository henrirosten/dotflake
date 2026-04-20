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
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t14s
    ./hardware-configuration.nix
  ]
  ++ (with outputs.nixosModules; [
    common-nix
    host-common
    laptop
    gui
    ssh
    hrosten.nixosModule
  ]);

  networking.hostName = "t14s";

  # Keep the host layout aligned with x1, but avoid carrying over its
  # Carbon-specific i915 workarounds to this different ThinkPad model.
  services.avahi.enable = false;
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
        outputs.homeModules.gui-extras
      ];
    };
}
