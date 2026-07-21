{ pkgs, lib, ... }:
{
  imports = [
    ./vscode.nix
  ];

  # fontconfig 2.18.x introduced pattern "genericfamily" guessing
  # (48-guessfamily.conf) that Chromium's vendored fontconfig copy scores by
  # enum distance ahead of the family name, so browser UI queries like
  # "Cantarell" resolve to monospace or serif fonts in Chrome and Electron
  # apps. Strip the guessed genericfamily from patterns; this runs at the
  # 50-user.conf include point, after 48-guessfamily and 49-sansserif (the
  # only configs that touch it), restoring pre-2.18 match behavior.
  # TODO: Remove once nixpkgs#541553 is fixed and Chromium/Electron handle
  # the new presets: https://github.com/NixOS/nixpkgs/issues/541553
  xdg.configFile."fontconfig/conf.d/50-no-genericfamily.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <match target="pattern">
        <edit name="genericfamily" mode="delete_all"/>
      </match>
    </fontconfig>
  '';

  home = {
    packages = with pkgs; [
      # Re-enable once nixpkgs burpsuite no longer requires a flaky vendor fetch at build time.
      # burpsuite
      chromium
      firefox
      flameshot
      gedit
      gnome-terminal
      gnome-tweaks
      google-chrome
      keepass
      libreoffice-fresh
      meld
    ];
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      show-battery-percentage = lib.hm.gvariant.mkBoolean true;
      gtk-enable-primary-paste = lib.hm.gvariant.mkBoolean true;
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
