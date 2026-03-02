{ pkgs, lib, ... }:
let
  git-cola-dark = pkgs.symlinkJoin {
    name = "git-cola-dark";
    paths = [ pkgs.git-cola ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/git-cola" \
        --set QT_STYLE_OVERRIDE adwaita-dark \
        --set QT_QPA_PLATFORMTHEME gtk3
    '';
  };
in
{
  imports = [
    ./vscode.nix
  ];

  home = {
    packages = with pkgs; [
      burpsuite
      chromium
      firefox
      flameshot
      gedit
      git-cola-dark
      google-chrome
      gnome-terminal
      gnome-tweaks
      keepass
      libreoffice
      meld
      wireshark
    ];
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      show-battery-percentage = lib.hm.gvariant.mkBoolean true;
    };
    # Keyboard repeat settings are configured system-wide in nix-modules/gui.nix
    # via services.xserver.autoRepeatDelay and autoRepeatInterval
    "org/gnome/desktop/sound" = {
      event-sounds = lib.hm.gvariant.mkBoolean false;
    };
    "org/gnome/desktop/notifications" = {
      show-banners = lib.hm.gvariant.mkBoolean false;
    };
    "org/gnome/desktop/calendar" = {
      show-weekday = lib.hm.gvariant.mkBoolean true;
    };
    "org/gnome/shell" = {
      favorite-apps = [
        "org.gnome.Nautilus.desktop"
        "org.gnome.Terminal.desktop"
        "google-chrome.desktop"
        "keepass.desktop"
      ];
    };
  };
}
