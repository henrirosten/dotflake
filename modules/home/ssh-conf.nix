{
  programs.ssh = {
    enableDefaultConfig = false;
    enable = true;
    settings = {
      "*" = {
        ControlMaster = "auto";
        ControlPath = "~/.ssh/%C";
      };
    };
  };
}
