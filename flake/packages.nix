{
  forAllSystems,
  mkPkgs,
  agentVms ? { },
  localAgentVms ? { },
  nocturnLocalAgentVms ? { },
  agentSystem ? null,
}:
forAllSystems (
  system:
  let
    pkgs = mkPkgs system;
    localProfiles = import ./local-model-profiles.nix;
    hostTools = [ pkgs.git ];
    guestTools = with pkgs; [
      git
      coreutils
      util-linux
      python3
    ];
    mkAgentLauncher =
      {
        name,
        vm,
        localModel ? false,
        localModelName ? localProfiles.laptop.name,
        defaultInstance ? if localModel then "local" else "default",
        defaultCpus ? if localModel then "4" else "2",
        defaultRamMb ? "8192",
      }:
      let
        replacements = {
          mktemp = "${pkgs.coreutils}/bin/mktemp";
          secretTool = "${pkgs.libsecret}/bin/secret-tool";
          qemuImg = "${pkgs.qemu}/bin/qemu-img";
          mkfsExt4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
          vmRunner = "${vm}/bin/run-generic-vm";
          launcherName = name;
          backend = if localModel then "local" else "cloud";
          inherit
            localModelName
            defaultInstance
            defaultCpus
            defaultRamMb
            ;
          defaultNetwork = if localModel then "offline" else "online";
          defaultExec = if localModel then "local-agent" else "";
        };
      in
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.jq
          pkgs.nix
          pkgs.passt
          pkgs.iproute2
          (import ./packages.nix { inherit forAllSystems mkPkgs; }).${system}.dotflake-agent
        ];
        text = builtins.replaceStrings (map (key: "@${key}@") (
          builtins.attrNames replacements
        )) (builtins.attrValues replacements) (builtins.readFile ../scripts/dotflake-vm.sh);
      };
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
    dotflake-vm = mkAgentLauncher {
      name = "dotflake-vm";
      vm = agentVms.${system}.generic-vm;
    };
    dotflake-local-vm = mkAgentLauncher {
      name = "dotflake-local-vm";
      vm = localAgentVms.${system}.generic-vm;
      localModel = true;
    };
    dotflake-local-vm-nocturn = mkAgentLauncher {
      name = "dotflake-local-vm-nocturn";
      vm = nocturnLocalAgentVms.${system}.generic-vm;
      localModel = true;
      localModelName = localProfiles.nocturn.name;
      defaultInstance = "local-nocturn";
      defaultCpus = "8";
      defaultRamMb = "40960";
    };
  }
)
