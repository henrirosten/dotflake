{
  forAllSystems,
  mkPkgs,
  agentVms ? { },
  agentSystem ? null,
}:
forAllSystems (
  system:
  let
    pkgs = mkPkgs system;
    hostTools = [ pkgs.git ];
    guestTools = with pkgs; [
      git
      coreutils
      util-linux
      python3
    ];
  in
  {
    dotflake-agent = pkgs.runCommand "dotflake-agent" { } ''
      mkdir -p "$out/bin" "$out/lib"
      cp ${../scripts/agent-state.py} "$out/lib/dotflake_agent_state.py"
      substitute ${../scripts/dotflake-agent.py} "$out/bin/dotflake-agent" \
        --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3' \
        --replace-fail '@git@' '${pkgs.git}/bin/git' \
        --replace-fail '@modulePath@' "$out/lib" \
        --replace-fail '@runtimePath@' '${pkgs.lib.makeBinPath hostTools}'
      chmod +x "$out/bin/dotflake-agent"
    '';

    dotflake-agent-guest = pkgs.symlinkJoin {
      name = "dotflake-agent-guest";
      paths =
        map
          (
            name:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = guestTools;
              text = builtins.readFile ../scripts/${name}.sh;
            }
          )
          [
            "agent-init"
            "agent-export"
            "agent-update"
          ];
    };
  }
  // pkgs.lib.optionalAttrs (system == agentSystem) {
    dotflake-agent-vm = agentVms.${system}.generic-vm;
    dotflake-vm =
      let
        vm = agentVms.${system}.generic-vm;
        replacements = {
          mktemp = "${pkgs.coreutils}/bin/mktemp";
          secretTool = "${pkgs.libsecret}/bin/secret-tool";
          qemuImg = "${pkgs.qemu}/bin/qemu-img";
          mkfsExt4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
          vmRunner = "${vm}/bin/run-generic-vm";
        };
      in
      pkgs.writeShellApplication {
        name = "dotflake-vm";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.jq
          pkgs.nix
          (import ./packages.nix { inherit forAllSystems mkPkgs; }).${system}.dotflake-agent
        ];
        text = builtins.replaceStrings (map (name: "@${name}@") (
          builtins.attrNames replacements
        )) (builtins.attrValues replacements) (builtins.readFile ../scripts/dotflake-vm.sh);
      };
  }
)
