#!/usr/bin/env bash
set -euo pipefail

if [ "${TRACE:-0}" = "1" ]; then
  set -x
fi

################################################################################

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "command '$1' is not installed"
  fi
}

append_nix_conf_if_missing() {
  local line="$1"
  local conf_file="$2"
  local write_mode="$3"

  if [ "$write_mode" = "system" ]; then
    sudo mkdir -p "$(dirname "$conf_file")"
    sudo touch "$conf_file"
    if ! sudo grep -Fqx "$line" "$conf_file" 2>/dev/null; then
      echo "$line" | sudo tee -a "$conf_file" >/dev/null
    fi
  else
    mkdir -p "$(dirname "$conf_file")"
    touch "$conf_file"
    if ! grep -Fqx "$line" "$conf_file" 2>/dev/null; then
      echo "$line" >>"$conf_file"
    fi
  fi
}

supports_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

has_nix_daemon_service() {
  supports_systemd || return 1
  # Capture output first to avoid pipefail propagating a non-zero exit
  # from systemctl (e.g. due to broken/masked units) to the pipeline.
  local units
  units="$(systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}')" || true
  echo "$units" | grep -Fxq "nix-daemon.service"
}

selinux_enabled() {
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    [ -n "$mode" ] && [ "$mode" != "Disabled" ]
    return
  fi
  [ -d /sys/fs/selinux ] && [ -f /sys/fs/selinux/enforce ]
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  else
    die "unsupported package manager (supported: apt, dnf, yum, pacman, zypper, apk)"
  fi
}

install_prerequisites() {
  local package_manager="$1"

  case "$package_manager" in
  apt)
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends ca-certificates curl xz-utils
    ;;
  dnf)
    sudo dnf -y makecache
    sudo dnf -y install ca-certificates curl xz
    ;;
  yum)
    sudo yum -y makecache
    sudo yum -y install ca-certificates curl xz
    ;;
  pacman)
    sudo pacman -Sy --noconfirm ca-certificates curl xz
    ;;
  zypper)
    sudo zypper --non-interactive --gpg-auto-import-keys refresh
    sudo zypper --non-interactive install --no-recommends ca-certificates curl xz
    ;;
  apk)
    sudo apk update
    sudo apk add ca-certificates curl xz
    ;;
  *)
    die "unsupported package manager '$package_manager'"
    ;;
  esac
}

curl_fetch() {
  local url="$1"

  if curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"; then
    curl -fsSL --retry 5 --retry-all-errors "$url"
  else
    curl -fsSL --retry 5 "$url"
  fi
}

install_nix() {
  local install_type="$1"
  local installer_url="https://nixos.org/nix/install"
  local current_user
  current_user="$(id -un)"

  case "$install_type" in
  single)
    sh <(curl_fetch "$installer_url") --yes --no-daemon
    ;;
  multi)
    # The Nix installer may fail to start nix-daemon.socket if systemd
    # considers the service already active. This is harmless because
    # restart_nix_daemon handles the daemon setup after install.
    sh <(curl_fetch "$installer_url") --yes --daemon || {
      if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
        echo "Info: Nix installer exited with an error but nix binary is present; continuing."
      else
        die "Nix installer failed"
      fi
    }
    ;;
  *)
    die "unknown installation type: '$install_type'"
    ;;
  esac

  # Fix https://github.com/nix-community/home-manager/issues/3734:
  sudo mkdir -m 0755 -p "/nix/var/nix/profiles/per-user/$current_user" "/nix/var/nix/gcroots/per-user/$current_user"
  if getent group nixbld >/dev/null 2>&1; then
    sudo chown -R "$current_user:nixbld" "/nix/var/nix/profiles/per-user/$current_user"
  else
    sudo chown -R "$current_user:$current_user" "/nix/var/nix/profiles/per-user/$current_user"
  fi

  # Enable flakes.
  if [ "$install_type" = "multi" ]; then
    append_nix_conf_if_missing "experimental-features = nix-command flakes" "/etc/nix/nix.conf" "system"
    append_nix_conf_if_missing "trusted-users = root $current_user" "/etc/nix/nix.conf" "system"
  else
    append_nix_conf_if_missing "experimental-features = nix-command flakes" "$HOME/.config/nix/nix.conf" "user"
  fi

  # https://github.com/NixOS/nix/issues/1078#issuecomment-1019327751
  for f in /nix/var/nix/profiles/default/bin/nix*; do
    [ -e "$f" ] || continue
    sudo ln -fs "$f" "/usr/bin/$(basename "$f")"
  done
}

restart_nix_daemon() {
  has_nix_daemon_service || return 0

  # Always do a clean stop/start. The Nix installer starts the daemon via
  # socket activation, but the --daemon flag causes it to fork and delete
  # the socket file, breaking new connections.
  sudo systemctl stop nix-daemon.service nix-daemon.socket
  sudo pkill -KILL -x nix-daemon 2>/dev/null || true
  sudo systemctl reset-failed nix-daemon.service 2>/dev/null || true
  sudo systemctl start nix-daemon.socket
  sudo systemctl start nix-daemon.service

  if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
    sudo systemctl status nix-daemon.socket nix-daemon.service --no-pager || true
    die "nix-daemon socket file missing after restart"
  fi
}

load_nix_environment() {
  local install_type="$1"

  if [ "$install_type" = "multi" ]; then
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
      # shellcheck disable=SC1091
      . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    elif [ -f /etc/profile.d/nix.sh ]; then
      # shellcheck disable=SC1091
      . /etc/profile.d/nix.sh
    fi
  else
    if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
      # shellcheck disable=SC1091
      . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
  fi

  if [ -d "$HOME/.nix-profile/bin" ]; then
    case ":$PATH:" in
    *":$HOME/.nix-profile/bin:"*) ;;
    *)
      export PATH="$HOME/.nix-profile/bin:$PATH"
      ;;
    esac
  fi
}

uninstall_nix() {
  # Stop systemd services first, before removing /nix, so the unit files
  # and daemon binary are still present for a clean shutdown.
  if has_nix_daemon_service; then
    sudo systemctl stop nix-daemon.socket nix-daemon.service
    sudo systemctl disable nix-daemon.socket nix-daemon.service
    sudo find /etc/systemd -iname "*nix-daemon*" -delete
    sudo find /usr/lib/systemd -iname "*nix-daemon*" -delete
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
  fi
  # Kill any remaining nix-daemon processes that systemd didn't clean up.
  sudo pkill -KILL -x nix-daemon 2>/dev/null || true
  # https://github.com/NixOS/nix/issues/1402
  if grep -qE '^nixbld[0-9]*:' /etc/passwd; then
    while IFS=: read -r nix_user _; do
      sudo userdel -r "$nix_user" || true
    done < <(grep -E '^nixbld[0-9]*:' /etc/passwd)
  fi
  if getent group nixbld >/dev/null 2>&1; then
    sudo groupdel nixbld || true
  fi
  rm -rf "$HOME/.nix-channels" \
    "$HOME/.nix-defexpr" \
    "$HOME/.nix-profile" \
    "$HOME/.config/nixpkgs" \
    "$HOME/.config/nix" \
    "$HOME/.config/home-manager" \
    "$HOME/.local/state/nix" \
    "$HOME/.local/state/home-manager"
  sudo rm -f /etc/profile.d/nix.sh
  if [ -d "/nix" ]; then
    sudo rm -rf /nix
  fi
  if [ -d "/etc/nix" ]; then
    sudo rm -fr /etc/nix.bak
    sudo mv /etc/nix /etc/nix.bak
  fi
  if [ -d "$HOME/.cache/nix" ]; then
    rm -fr "$HOME/.cache/nix.bak"
    mv "$HOME/.cache/nix" "$HOME/.cache/nix.bak"
  fi
  sudo find /etc -iname "*backup-before-nix*" -delete
  while IFS= read -r nix_link; do
    sudo rm -f "$nix_link"
  done < <(find /usr/bin -maxdepth 1 -type l -name "nix*" -lname "/nix/*" 2>/dev/null || true)
  [ -f "$HOME/.profile" ] && sed -i "/\/nix/d" "$HOME/.profile"
  [ -f "$HOME/.bash_profile" ] && sed -i "/\/nix/d" "$HOME/.bash_profile"
  [ -f "$HOME/.bashrc" ] && sed -i "/\/nix/d" "$HOME/.bashrc"
  unset NIX_PATH
}

outro() {
  set +x || true
  echo ""
  local nixpkgs_ver
  nixpkgs_ver="$(nix-instantiate --eval -E '(import <nixpkgs> {}).lib.version' 2>/dev/null)"
  if [ -n "$nixpkgs_ver" ]; then
    echo "Installed nixpkgs version: $nixpkgs_ver"
  else
    die "failed reading installed nixpkgs version"
  fi
  echo ""
  if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    echo "To activate nix in this shell, run:"
    echo "  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  elif [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    echo "To activate nix in this shell, run:"
    echo "  . $HOME/.nix-profile/etc/profile.d/nix.sh"
  else
    echo "Open a new terminal for the changes to take effect."
  fi
  echo ""
}

################################################################################

main() {
  local install_mode_input="${1:-auto}"
  local install_type="$install_mode_input"
  local package_manager=""

  if [ "$#" -gt 1 ] || { [ "$install_type" != "auto" ] && [ "$install_type" != "multi" ] && [ "$install_type" != "single" ]; }; then
    die "usage: $0 [auto|multi|single]"
  fi

  if [ "$install_type" = "auto" ]; then
    if supports_systemd; then
      install_type="multi"
    else
      install_type="single"
      echo "Info: systemd not detected, using single-user Nix install."
    fi
  elif [ "$install_type" = "multi" ] && ! supports_systemd; then
    die "multi-user install requires systemd. Re-run with '$0 single'."
  fi

  if [ "$install_type" = "multi" ] && selinux_enabled; then
    if [ "$install_mode_input" = "auto" ]; then
      install_type="single"
      echo "Info: SELinux detected, using single-user Nix install."
    else
      die "multi-user install is not supported when SELinux is enabled. Re-run with '$0 single'."
    fi
  fi

  require_command "sudo"
  package_manager="$(detect_package_manager)"
  echo "Info: detected package manager: $package_manager"
  install_prerequisites "$package_manager"
  uninstall_nix
  install_nix "$install_type"
  if [ "$install_type" = "multi" ]; then
    restart_nix_daemon
  fi
  load_nix_environment "$install_type"
  require_command "nix-shell"
  outro
}

################################################################################

main "$@"

################################################################################
