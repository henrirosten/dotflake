{
  common-nix = import ./common-nix.nix;
  gui = import ./gui.nix;
  host-common = import ./host-common.nix;
  laptop = import ./laptop.nix;
  gnome-freeze-watchdog = import ./gnome-freeze-watchdog.nix;
  gpu-hang-capture = import ./gpu-hang-capture.nix;
  ssh = import ./ssh.nix;
  remotebuild = import ./remotebuild.nix;
}
