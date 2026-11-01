{
  pkgs,
  inputs,
  ...
}:
{
  # Compatibility entrypoint for consumers that only want Codex.
  home.packages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codex
  ];
}
