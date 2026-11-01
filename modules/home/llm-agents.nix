{
  pkgs,
  inputs,
  ...
}:
{
  home.packages = import ../../flake/llm-agents.nix {
    inherit inputs;
    system = pkgs.stdenv.hostPlatform.system;
  };
}
