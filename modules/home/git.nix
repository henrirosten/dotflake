{ user }:
{ pkgs, ... }:
{
  programs.lazygit = {
    enable = true;
    settings = {
      gui.authorColors = {
        "Henri Rosten" = "#89b4fa";
      };
      gui.theme = {
        activeBorderColor = [
          "#89b4fa"
          "bold"
        ];
        inactiveBorderColor = [ "#a6adc8" ];
        optionsTextColor = [ "#89b4fa" ];
        selectedLineBgColor = [ "#313244" ];
        cherryPickedCommitBgColor = [ "#45475a" ];
        cherryPickedCommitFgColor = [ "#89b4fa" ];
        unstagedChangesColor = [ "#f38ba8" ];
        defaultFgColor = [ "#cdd6f4" ];
        searchingActiveBorderColor = [ "#f9e2af" ];
      };
    };
  };

  programs.git = {
    enable = true;
    package = pkgs.gitFull;
    signing.format = "openpgp";
    settings = {
      user = {
        inherit (user) name;
        inherit (user) email;
      };
      core = {
        whitespace = "trailing-space,space-before-tab";
        editor = "vim";
      };
      commit.sign = true;
      merge.tool = "meld";
      mergetool."meld".cmd = "meld $LOCAL $MERGED $REMOTE --output $MERGED";
      difftool."meld".cmd = "meld $LOCAL $REMOTE";
      init.defaultBranch = "main";
      credential.helper = "cache --timeout=3600";
    };
  };
}
