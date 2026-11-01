{
  inputs,
  forAllSystems,
  mkPkgs,
  mkPreCommitCheck,
  defaultSystem,
  stateVersion,
  moduleOutputs,
  packages,
}:
forAllSystems (
  system:
  let
    lib = inputs.nixpkgs.lib;
    pkgs = mkPkgs system;
    agentCliPackages = import ./llm-agents.nix { inherit inputs system; };
    testSpecialArgs = {
      inherit
        inputs
        stateVersion
        ;
      outputs = moduleOutputs // {
        inherit packages;
      };
    };
  in
  {
    pre-commit-check = mkPreCommitCheck system;
    dotflake-agent =
      pkgs.runCommand "dotflake-agent-tests"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.git
            packages.${system}.dotflake-agent
            packages.${system}.dotflake-agent-guest
          ];
        }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          python3 ${../tests/dotflake-agent.py}
          touch "$out"
        '';
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
          environment.systemPackages = lib.mkAfter agentCliPackages;
        };
      testScript = ''
        start_all()
        x1.wait_for_unit("default.target")
        x1.wait_until_succeeds("systemctl is-system-running --wait | grep -qx running")
        x1.succeed("test -z \"$(systemctl --failed --plain --no-legend)\"")
        ${lib.concatMapStringsSep "\n" (package: ''
          x1.succeed("command -v ${package.meta.mainProgram}")
          x1.succeed("${package.meta.mainProgram} --version")
        '') agentCliPackages}
      '';
    };
  }
)
