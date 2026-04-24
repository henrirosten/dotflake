{
  bash = import ./bash.nix;
  codex-cli = import ./codex-cli.nix;
  gui-extras = import ./gui-extras.nix;
  git = import ./git.nix;
  shell-common = import ./shell-common.nix;
  ssh-conf = import ./ssh-conf.nix;
  starship = import ./starship.nix;
  vpn = import ./vpn.nix;
  vim = import ./vim.nix;
  vscode = import ./vscode.nix;
  zsh = import ./zsh.nix;
}
