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

  # i915 tuning for this iGPU (Alder/Raptor Lake-P, PCI 8086:a7a1).
  #
  # enable_psr=0 and enable_dc=0 are long-standing display-power workarounds
  # on this hardware generation; kept to avoid reintroducing known-broken
  # code paths. i915.force_probe=a7a1 is contributed by nixos-hardware's
  # lenovo-thinkpad-x1-11th-gen module.
  #
  # If GPU hangs recur (symptoms: `GPU HANG`, `device wedged`, or
  # `Failed to reset chip` in dmesg; display frozen until power-cycle),
  # captured diagnostics land in /var/log/gpu-hang/<UTC-timestamp>/ —
  # see modules/nixos/gpu-hang-capture.nix.
  #
  # Escalation options to try one at a time after confirming kernel and
  # linux-firmware are current (each requires a rebuild + reboot):
  #   - i915.enable_guc=0   Disable GuC submission, fall back to legacy
  #                         execbuf. Directly targets the failure mode
  #                         where GuC-based reset times out
  #                         (`Failed to reset GuC, ret = -110`). Downside:
  #                         loses HuC-based video decode/encode acceleration.
  #                         Do NOT combine with modules that require HuC.
  #   - i915.reset=1        Restrict i915 to per-engine resets only (no
  #                         full-chip reset). Worth trying if chip-wide
  #                         reset is the problematic path.
  # Last incident: 2026-04-15, one-off, Chrome GPU process (rcs0) was the
  # trigger. Prior 6-day boot had zero hangs, so none of the above are
  # applied by default.
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
