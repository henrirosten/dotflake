_: {
  imports = [ ./shell-common.nix ];

  programs.bash = {
    enable = true;
    historyFileSize = 1000000;
    historySize = 1000000;
    shellOptions = [
      "histappend"
      "checkwinsize"
    ];
    bashrcExtra = ''
      # Source shared shell functions
      [ -f "$HOME/.local/share/shell-functions.sh" ] && . "$HOME/.local/share/shell-functions.sh"

      export HISTCONTROL=ignoreboth
      PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
      #PROMPT_COLOR="1;90m"
      PROMPT_COLOR="1;32m"
      export PS1="\n\[\033[$PROMPT_COLOR\][\[\e]0;\u@\h: \w\a\]\u@\h:\w]\\$\[\033[0m\] "
    '';
    initExtra = ''
      if [ -z ''${LANG+x} ]; then LANG=en_US.utf8; fi
    '';
  };
}
