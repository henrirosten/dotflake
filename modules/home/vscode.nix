{ pkgs, ... }:
{
  programs.vscode = {
    enable = true;
    mutableExtensionsDir = true;
    # https://github.com/nix-community/nix-vscode-extensions/blob/master/data/cache/open-vsx-latest.json
    profiles.default.extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
      jnoortheen.nix-ide
      ms-python.python
      mechatroner.rainbow-csv
      shardulm94.trailing-spaces
      bierner.github-markdown-preview
      eamodio.gitlens
      redhat.vscode-yaml
      nhoizey.gremlins
    ];
  };
}
