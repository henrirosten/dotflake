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
    inputs.nixos-hardware.nixosModules.lenovo-thinkpad-t480
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

  nixpkgs.overlays = [
    (_final: prev: {
      # Backport Intel's missing include fix for GCC 16 (compute-runtime#908).
      # Remove when the nixpkgs pin includes https://github.com/NixOS/nixpkgs/pull/568713.
      intel-compute-runtime-legacy1 = prev.intel-compute-runtime-legacy1.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/intel/compute-runtime/commit/c1eb6c1a183c2f69e0d6e9ed5aa042fac2201217.patch";
            hash = "sha256-O8ZJaxIr4TF73T+fyEbNjEYFbgwLxIUWoYnorxh8ZTo=";
          })
        ];
      });

      throttled = prev.throttled.overrideAttrs (old: {
        pythonPath = (old.pythonPath or [ ]) ++ [ prev.python3Packages.dbus-next ];
      });
    })
  ];

  networking.hostName = "t480";

  system.autoUpgrade.dates = "02:00";

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
