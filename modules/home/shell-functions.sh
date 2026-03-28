#!/usr/bin/env bash
# Shared shell functions for bash and zsh

# Disable ctrl-s (pause terminal output)
stty -ixon 2>/dev/null

own-minhist() {
  local histfile="${HISTFILE:-$HOME/.bash_eternal_history}"
  cp "$histfile" "$histfile.old"
  nl "$histfile" | sort -k2 -k 1,1nr | uniq -f1 | sort -n | cut -f2 >"$histfile.tmp"
  mv "$histfile.tmp" "$histfile"
  echo "Deduplicated $histfile. Old history in $histfile.old"
}

own-allfiles() {
  sudo find / -type f ! -path "/dev/*" ! -path "/sys/*" ! -path "/proc/*" ! -path "/run/*" |
    tee "$HOME/allfiles.txt" >/dev/null
  echo "Wrote $HOME/allfiles.txt"
}

own-find-largest() {
  if [ -z "$1" ]; then
    findpath="$PWD"
  else
    findpath="$1"
  fi
  if [ -z "$2" ]; then
    n="20"
  else
    n="$2"
  fi
  find "$findpath" -type f -exec du -h {} + | sort -r -h | head -n "$n"
}

own-find-links() {
  if [ -z "$1" ]; then
    findpath="$PWD"
  else
    findpath="$1"
  fi
  find "$findpath" -type l -printf '%p -> ' -exec readlink -f {} \;
}

own-nix-store-symlinks() {
  # Find all symlinks in HOME that point somewhere in /nix/store.
  # grep -v removes (home-manager managed) dotfiles from the output results.
  own-find-links "$HOME" | grep "/nix/store" | grep -v "$HOME/\."
}

own-nix-info() {
  local nixpkgs_version
  local nix_path_display
  local root_channels

  nixpkgs_version="$(nix-instantiate --eval -E '(import <nixpkgs> {}).lib.version' 2>/dev/null || true)"
  nix_path_display="${NIX_PATH:-<unset>}"
  if sudo -n true >/dev/null 2>&1; then
    root_channels="$(sudo -n "$(command -v nix-channel)" --list)"
  else
    root_channels="<sudo required>"
  fi

  echo "nix-info:"
  nix-info -m
  echo ""
  echo "nix resolution:"
  echo " - NIX_PATH: $nix_path_display"
  if [ -n "$nixpkgs_version" ]; then
    echo " - current <nixpkgs> version: $nixpkgs_version"
    if [ -n "${NIX_PATH:-}" ]; then
      echo " - current <nixpkgs> source: NIX_PATH / shell environment"
    else
      echo " - current <nixpkgs> source: default nixPath search order"
    fi
  else
    echo " - current <nixpkgs> version: unavailable"
  fi
  echo ""
  echo "nix-channel (legacy subscriptions):"
  echo " - root: $root_channels"
  echo " - $USER: $(nix-channel --list)"
}

own-nix-free() {
  local gb="${1:-100}"
  nix-collect-garbage -d --max-freed "$((gb * 1024 * 1024 * 1024))"
}

own-nix-clean() {
  nix-collect-garbage -d
  # notify if it seems some symlinks prevent full cleanup
  if own-nix-store-symlinks >/dev/null 2>&1; then
    echo ""
    echo "Note: following symlinks in '$HOME' prevent nix-collect-garbage to fully clean the store:"
    own-nix-store-symlinks
  fi
  echo ""
  echo "Consider manually removing old profiles from '/nix/var/nix/profiles':"
  find /nix/var/nix/profiles/
  echo ""
  echo "Consider manually removing logs from '/nix/var/log/nix/drvs/'"
  own-find-largest /nix/var/log/nix/drvs/ 10
}

own-journal-clean() {
  sudo journalctl --rotate
  sudo journalctl --vacuum-time=1s
}

own-tmp-clean() {
  if ! command -v fuser >/dev/null 2>&1; then
    echo "Error: fuser not found (install psmisc)" >&2
    return 1
  fi
  find /tmp -mindepth 1 ! -exec fuser -s {} \; -delete 2>/dev/null
}

own-nix-diff() {
  nix profile diff-closures --profile "${1:-/nix/var/nix/profiles/system}"
}

own-nix-why() {
  nix-store --query --roots "$1"
}

own-nix-size() {
  echo "Nix store:"
  du -sh /nix/store
  echo ""
  echo "Current system profile closure:"
  nix path-info -Sh /nix/var/nix/profiles/system 2>/dev/null
}

own-disk-usage() {
  echo "Nix store:"
  du -sh /nix/store 2>/dev/null
  echo "Journal:"
  journalctl --disk-usage 2>/dev/null
  echo "Tmp:"
  du -sh /tmp 2>/dev/null
  echo "Home:"
  du -sh "$HOME" 2>/dev/null
}

own-listening() {
  ss -tlnp
}

own-stale-services() {
  # Find processes using deleted nix store paths (common after nixos-rebuild)
  sudo grep -rl '/nix/store.*deleted' /proc/*/maps 2>/dev/null |
    cut -d/ -f3 |
    sort -un |
    while read -r pid; do
      printf "%-8s %s\n" "$pid" "$(cat /proc/"$pid"/comm 2>/dev/null)"
    done
}

own-backup() {
  cp -a "$1" "$1.$(date +%Y-%m-%d)"
}

own-recent() {
  find "${1:-.}" -type f -mtime "-${2:-1}" -printf '%T+ %p\n' | sort -r
}
