# Shared shell configuration for bash and zsh
let
  historyFile = "$HOME/.bash_eternal_history";
in
{
  home.shellAliases = {
    ls = "ls --color=auto";
    grep = "grep --color=auto";
  };

  home.sessionVariables = {
    XDG_DATA_DIRS = "$HOME/.nix-profile/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}";
    # Shared history file for bash and zsh (preserves existing history)
    HISTFILE = historyFile;
  };

  # Shared shell functions sourced by both bash and zsh
  home.file.".local/share/shell-functions.sh" = {
    executable = false;
    text = builtins.readFile ./shell-functions.sh;
  };
}
