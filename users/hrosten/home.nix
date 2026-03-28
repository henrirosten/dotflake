{
  pkgs,
  inputs,
  outputs,
  stateVersion,
  ...
}:
let
  user = (import ./hrosten.nix).user;
in
{
  imports = [
    outputs.homeModules.bash
    outputs.homeModules.codex-cli
    (outputs.homeModules.git { inherit user; })
    outputs.homeModules.ssh-conf
    outputs.homeModules.starship
    outputs.homeModules.vim
    outputs.homeModules.zsh
    inputs.nix-index-database.homeModules.nix-index
  ];

  nixpkgs.config.allowUnfree = true;

  fonts.fontconfig.enable = true;
  home = {
    username = user.username;
    homeDirectory = user.homedir;
    packages = with pkgs; [
      bat
      cantarell-fonts
      claude-code
      csvkit
      curl
      dig.dnsutils
      file
      gh
      htop
      jq
      net-tools
      nix-info
      openconnect
      openfortivpn
      openvpn
      ripgrep
      inputs.sbomnix.packages.${pkgs.stdenv.hostPlatform.system}.default
      tree
      wget
      nerd-fonts.fira-code
      nerd-fonts.droid-sans-mono
      psmisc
      source-code-pro
    ];
    sessionVariables = {
      NIX_PATH = "nixpkgs=${inputs.nixpkgs}";
      # Centralized EDITOR setting for all shells
      EDITOR = "vim";
    };
    inherit stateVersion;
  };
  systemd.user.startServices = "sd-switch";
  programs = {
    home-manager.enable = true;
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    # show what package provides a commands when it's not found
    nix-index = {
      enable = true;
      enableZshIntegration = true;
      enableBashIntegration = true;
    };
    # run commands without installing them
    # , <cmd>
    nix-index-database.comma.enable = true;
  };
  xdg.configFile."nix/nix.conf".text = ''
    substituters = https://cache.nixos.org/
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
  '';
  # Ref: https://github.com/nix-community/home-manager/issues/5552
  # Workaround for HM passing a nonexistent units dir to sd-switch
  xdg.configFile."systemd/user/.hm-keep".text = "";
}
