{
  imports = [
    ./gnome-freeze-watchdog.nix
    ./gpu-hang-capture.nix
  ];

  # Work around Mutter KMS frame assertion failures (mutter#3265, MR !3912).
  # Forces mutter to use a regular thread for KMS operations instead of a
  # real-time one, eliminating scheduling-related races on monitor hotplug
  # and suspend/resume.
  environment.variables.MUTTER_DEBUG_KMS_THREAD_TYPE = "user";

  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    xserver = {
      enable = true;
      xkb.layout = "fi";
      autoRepeatDelay = 200;
      autoRepeatInterval = 20;
    };
  };

  # use X keyboard options in console
  console.useXkbConfig = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
}
