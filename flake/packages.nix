{
  forAllSystems,
  mkPkgs,
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
      mkdir -p "$out/bin"
      substitute ${../scripts/dotflake-agent.py} "$out/bin/dotflake-agent" \
        --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3' \
        --replace-fail '@git@' '${pkgs.git}/bin/git' \
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
)
