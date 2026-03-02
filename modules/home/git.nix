{ user }:
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    lazygit
  ];

  programs.git = {
    enable = true;
    package = pkgs.gitFull;
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
