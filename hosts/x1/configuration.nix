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
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-11th-gen
    ./hardware-configuration.nix
    (outputs.nixosModules.remotebuild {
      sshUser = hrosten.user.username;
      sshKey = "${hrosten.user.homedir}/.ssh/id_ed25519";
    })
  ]
  ++ (with outputs.nixosModules; [
    common-nix
    host-common
    laptop
    gui
    ssh
    hrosten.nixosModule
  ]);

  networking.hostName = "x1";

  # Intel iGPU freeze workaround on this hardware generation:
  # keep cursor/mouse responsive while GNOME input/UI stops.
  boot.kernelParams = [
    "i915.enable_psr=0"
    "i915.enable_dc=0"
  ];

  services.avahi.enable = false;
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
