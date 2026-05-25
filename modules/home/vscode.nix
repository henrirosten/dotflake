{ pkgs, ... }:
{
  programs.vscode = {
    enable = true;
    mutableExtensionsDir = true;
    # https://github.com/nix-community/nix-vscode-extensions/blob/master/data/cache/open-vsx-latest.json
    profiles.default.extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
      jnoortheen.nix-ide
      # Temporary: disabled after the flake update because ms-python.python
      # depends on jedi-language-server 0.46.0, which requires jedi < 0.20,
      # while the current nixpkgs snapshot provides jedi 0.20.0.
      # ms-python.python
      mechatroner.rainbow-csv
      shardulm94.trailing-spaces
      bierner.github-markdown-preview
      eamodio.gitlens
      redhat.vscode-yaml
      nhoizey.gremlins
    ];
  };
}
