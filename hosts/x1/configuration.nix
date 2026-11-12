{
  inputs,
  outputs,
  pkgs,
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

  # i915 tuning for this iGPU (Alder/Raptor Lake-P, PCI 8086:a7a1).
  #
  # enable_psr=0 and enable_dc=0 are long-standing display-power workarounds
  # on this hardware generation; kept to avoid reintroducing known-broken
  # code paths. i915.force_probe=a7a1 is contributed by nixos-hardware's
  # lenovo-thinkpad-x1-11th-gen module.
  #
  # If GPU hangs recur (symptoms: `GPU HANG`, `device wedged`, or
  # `Failed to reset chip` in dmesg; display frozen until power-cycle),
  # captured diagnostics land in unique UTC-stamped directories under
  # /var/log/gpu-hang/ — see modules/nixos/gpu-hang-capture.nix.
  #
  # Escalation options to try one at a time after confirming kernel and
  # linux-firmware are current (each requires a rebuild + reboot):
  #   - i915.enable_guc=2   Disable GuC submission while keeping HuC loading.
  #                         Tests host submission instead of GuC scheduling;
  #                         GuC firmware still runs for HuC authentication.
  #   - i915.enable_guc=0   Disable both GuC submission and HuC loading.
  #                         Broader isolation test if enable_guc=2 still hangs;
  #                         HuC-dependent media features become unavailable.
  # reset=1 means full-GPU resets, not per-engine-only resets. The default
  # reset=2 already attempts engine resets; do not change it alongside GuC.
  # Parameter definitions: https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/i915_params.c
  # Last incident: 2026-11-12, kernel 7.3.3, GuC 70.49.4: rcs0 engine reset
  # failed, followed by Xwayland GPU HANG, failed chip reset, and a wedge.
  # The initial trigger is unknown. Keep these as experiments, not a
  # confirmed fix; see README for capturing diagnostics.
  boot.kernelParams = [
    "i915.enable_psr=0"
    "i915.enable_dc=0"
  ];
  hardware.intelgpu.vaapiDriver = "intel-media-driver";

  services.avahi.enable = false;
  system.autoUpgrade.dates = "weekly";

  # Agent VM launcher (see README); not in Home Manager, which the guest imports.
  environment.systemPackages = [ outputs.packages.${pkgs.stdenv.hostPlatform.system}.dotflake-vm ];

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
