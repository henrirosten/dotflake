{
  pkgs,
  stateVersion,
  ...
}:
let
  asGB = size: toString (size * 1024 * 1024 * 1024);
in
{
  system.stateVersion = stateVersion;
  time.timeZone = "Europe/Helsinki";
  i18n.defaultLocale = "en_US.UTF-8";
  boot.blacklistedKernelModules = [ "pcspkr" ];
  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;
  services.journald = {
    storage = "persistent";
    extraConfig = ''
      SystemMaxUse=1G
    '';
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "@wheel" ];
      # Ref:
      # https://nixos.wiki/wiki/Storage_optimization#Automation
      # https://nixos.org/manual/nix/stable/command-ref/conf-file.html#conf-min-free
      #
      # When free disk space in /nix/store drops below min-free during build,
      # perform a garbage-collection until max-free bytes are available or there
      # is no more garbage.
      min-free = asGB 20;
      max-free = asGB 100;
      # check the free disk space every 5 seconds
      min-free-check-interval = 5;
    };
    # Garbage collection, see:
    # https://search.nixos.org/options?type=packages&query=nix.gc
    gc = {
      automatic = true;
      dates = "weekly";
      options = pkgs.lib.mkDefault "--delete-older-than 14d";
      persistent = true;
    };
    optimise.automatic = true;
  };

  # Sometimes it fails if a store path is still in use.
  # This should fix intermediate issues.
  systemd.services.nix-gc.serviceConfig = {
    Restart = "on-failure";
  };

  # https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = false;
  # https://github.com/NixOS/nixpkgs/issues/296450
  systemd.services.NetworkManager-ensure-profiles.after = [ "NetworkManager.service" ];

  security = {
    sudo = {
      execWheelOnly = true;
      extraConfig = ''
        Defaults lecture = never
        Defaults passwd_timeout=0
      '';
    };
    audit.enable = true;
    auditd.enable = true;

    # Increase the maximum number of open files user limit, see ulimit -n
    pam.loginLimits = [
      {
        domain = "*";
        item = "nofile";
        type = "-";
        value = "8192";
      }
    ];
  };
  systemd.tmpfiles.rules = [
    # Codex currently hardcodes /usr/bin/bwrap on Linux.
    "L+ /usr/bin/bwrap - - - - ${pkgs.bubblewrap}/bin/bwrap"
  ];

  programs.zsh.enable = true;
  environment = {
    pathsToLink = [ "/share/zsh" ];
    shells = [ pkgs.zsh ];
  };
  programs.bash.completion.enable = true;
  users.defaultUserShell = pkgs.bash;

  networking = {
    networkmanager.enable = true;
    firewall.enable = true;
    enableIPv6 = false;
  };

  # Minimal system packages - user tools managed by home-manager
  environment.systemPackages = with pkgs; [
    git
    nixVersions.latest
  ];

  # Enable zramSwap: https://search.nixos.org/options?show=zramSwap.enable
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 150;
  };
  # https://wiki.archlinux.org/title/Zram#Optimizing_swap_on_zram:
  boot.kernel.sysctl = {
    "kernel.sysrq" = 1;
    "vm.swappiness" = 180;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.page-cluster" = 0;
  };
  systemd.user.settings.Manager.DefaultLimitNOFILE = 8192;
}
