{
  inputs,
  forAllSystems,
  mkPkgs,
  mkPreCommitCheck,
  defaultSystem,
  stateVersion,
  moduleOutputs,
}:
forAllSystems (
  system:
  let
    lib = inputs.nixpkgs.lib;
    pkgs = mkPkgs system;
    testSpecialArgs = {
      inherit
        inputs
        stateVersion
        ;
      outputs = moduleOutputs;
    };
  in
  {
    pre-commit-check = mkPreCommitCheck system;
  }
  // lib.optionalAttrs (system == defaultSystem) {
    x1-vm-smoke = pkgs.testers.runNixOSTest {
      name = "x1-vm-smoke";
      node.specialArgs = testSpecialArgs;
      node.pkgsReadOnly = false;
      # Avoid colliding with runNixOSTest's implicit single-node `machine`
      # alias when nixpkgs type-checks the generated Python test script.
      nodes.x1 =
        { lib, ... }:
        {
          imports = [ ../hosts/x1/configuration.nix ];
          services.getty.autologinUser = lib.mkForce "root";
          # Keep VM tests fast and deterministic by avoiding HM profile activation.
          systemd.services."home-manager-hrosten".enable = lib.mkForce false;
          environment.systemPackages = lib.mkAfter [
            inputs.codex-cli-nix.packages.${system}.default
            inputs.nix-claude-code.packages.${system}.default
          ];
        };
      testScript = ''
        start_all()
        x1.wait_for_unit("default.target")
        x1.wait_until_succeeds("systemctl is-system-running --wait | grep -qx running")
        x1.succeed("test -z \"$(systemctl --failed --plain --no-legend)\"")
        x1.succeed("command -v codex")
        x1.succeed("codex --help >/dev/null 2>&1 || codex-cli --help >/dev/null 2>&1")
        x1.succeed("command -v claude")
        x1.succeed("claude --version")
      '';
    };
  }
)
