#!/usr/bin/env bash
# Shared shell functions for bash and zsh

# Disable ctrl-s (pause terminal output)
stty -ixon 2>/dev/null

own-minhist() {
  if [ "${1:-}" = "-h" ]; then
    echo "Deduplicate shell history file"
    echo "Usage: own-minhist"
    return
  fi
  local histfile="${HISTFILE:-$HOME/.bash_eternal_history}"
  cp "$histfile" "$histfile.old"
  nl "$histfile" | sort -k2 -k 1,1nr | uniq -f1 | sort -n | cut -f2 >"$histfile.tmp"
  mv "$histfile.tmp" "$histfile"
  echo "Deduplicated $histfile. Old history in $histfile.old"
}

own-allfiles() {
  if [ "${1:-}" = "-h" ]; then
    echo "List every file on the system to ~/allfiles.txt"
    echo "Usage: own-allfiles"
    return
  fi
  sudo find / -type f ! -path "/dev/*" ! -path "/sys/*" ! -path "/proc/*" ! -path "/run/*" |
    tee "$HOME/allfiles.txt" >/dev/null
  echo "Wrote $HOME/allfiles.txt"
}

own-find-largest() {
  if [ "${1:-}" = "-h" ]; then
    echo "Show the n largest files under path"
    echo "Usage: own-find-largest [path] [n]"
    return
  fi
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
  if [ "${1:-}" = "-h" ]; then
    echo "Show all symlinks and their targets"
    echo "Usage: own-find-links [path]"
    return
  fi
  if [ -z "$1" ]; then
    findpath="$PWD"
  else
    findpath="$1"
  fi
  find "$findpath" -type l -printf '%p -> ' -exec readlink -f {} \;
}

own-nix-store-symlinks() {
  if [ "${1:-}" = "-h" ]; then
    echo "Find home directory symlinks pointing into /nix/store (excluding dotfiles)"
    echo "Usage: own-nix-store-symlinks"
    return
  fi
  # Find all symlinks in HOME that point somewhere in /nix/store.
  # grep -v removes (home-manager managed) dotfiles from the output results.
  own-find-links "$HOME" | grep "/nix/store" | grep -v "$HOME/\."
}

own-nix-info() {
  if [ "${1:-}" = "-h" ]; then
    echo "Print Nix version, NIX_PATH, and channel info"
    echo "Usage: own-nix-info"
    return
  fi
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
  if [ "${1:-}" = "-h" ]; then
    echo "Garbage-collect up to n GB from the Nix store (default: 100)"
    echo "Usage: own-nix-free [gb]"
    return
  fi
  local gb="${1:-100}"
  nix-collect-garbage -d --max-freed "$((gb * 1024 * 1024 * 1024))"
}

own-nix-clean() {
  if [ "${1:-}" = "-h" ]; then
    echo "Full garbage collect, warn about pinning symlinks, show old profiles and logs"
    echo "Usage: own-nix-clean"
    return
  fi
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
  if [ "${1:-}" = "-h" ]; then
    echo "Rotate and vacuum systemd journal"
    echo "Usage: own-journal-clean"
    return
  fi
  sudo journalctl --rotate
  sudo journalctl --vacuum-time=1s
}

own-tmp-clean() {
  if [ "${1:-}" = "-h" ]; then
    echo "Delete top-level entries in /tmp that no readable process has open"
    echo "Usage: own-tmp-clean"
    return
  fi
  # One /proc pass collects every top-level /tmp path referenced by a readable
  # process (open fds, cwd, exe, root, and memory-mapped files). The previous
  # per-file 'fuser' walk forked once per entry and hung on large /tmp trees.
  local in_use
  in_use="$(
    {
      find /proc -maxdepth 4 -type l -lname '/tmp/*' -printf '%l\n' 2>/dev/null
      awk '$NF ~ "^/tmp/"{print $NF}' /proc/[0-9]*/maps 2>/dev/null
    } | grep -v ' (deleted)$' | sed -n 's|^\(/tmp/[^/]\{1,\}\).*|\1|p' | sort -u
  )"
  local entry
  while IFS= read -r -d '' entry; do
    grep -qxF -- "$entry" <<<"$in_use" || rm -rf -- "$entry" 2>/dev/null
  done < <(find /tmp -mindepth 1 -maxdepth 1 -print0)
}

own-nix-diff() {
  if [ "${1:-}" = "-h" ]; then
    echo "Show diff-closures for a Nix profile (default: system)"
    echo "Usage: own-nix-diff [profile]"
    return
  fi
  nix profile diff-closures --profile "${1:-/nix/var/nix/profiles/system}"
}

own-nix-why() {
  if [ "${1:-}" = "-h" ]; then
    echo "Show GC roots keeping a store path alive"
    echo "Usage: own-nix-why <path>"
    return
  fi
  nix-store --query --roots "$1"
}

own-nix-size() {
  if [ "${1:-}" = "-h" ]; then
    echo "Print Nix store size and current system closure size"
    echo "Usage: own-nix-size"
    return
  fi
  echo "Nix store:"
  du -sh /nix/store
  echo ""
  echo "Current system profile closure:"
  nix path-info -Sh /nix/var/nix/profiles/system 2>/dev/null
}

own-disk-usage() {
  if [ "${1:-}" = "-h" ]; then
    echo "Summarize disk usage: nix store, journal, /tmp, home"
    echo "Usage: own-disk-usage"
    return
  fi
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
  if [ "${1:-}" = "-h" ]; then
    echo "Show listening TCP sockets"
    echo "Usage: own-listening"
    return
  fi
  ss -tlnp
}

own-stale-services() {
  if [ "${1:-}" = "-h" ]; then
    echo "Find processes using deleted nix store paths (need restart after rebuild)"
    echo "Usage: own-stale-services"
    return
  fi
  # Find processes using deleted nix store paths (common after nixos-rebuild)
  sudo grep -rl '/nix/store.*deleted' /proc/*/maps 2>/dev/null |
    cut -d/ -f3 |
    sort -un |
    while read -r pid; do
      printf "%-8s %s\n" "$pid" "$(cat /proc/"$pid"/comm 2>/dev/null)"
    done
}

own-reboot-needed() {
  if [ "${1:-}" = "-h" ]; then
    echo "Check if a reboot is required (kernel/initrd/modules differ between booted and current system)"
    echo "Usage: own-reboot-needed"
    return
  fi
  local booted current
  booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules})"
  current="$(readlink /run/current-system/{initrd,kernel,kernel-modules})"
  if [ "$booted" = "$current" ]; then
    echo "no reboot needed"
    return 0
  fi
  echo "reboot required"
  return 1
}

own-backup() {
  if [ "${1:-}" = "-h" ]; then
    echo "Copy file with a date-stamped suffix"
    echo "Usage: own-backup <file>"
    return
  fi
  cp -a "$1" "$1.$(date +%Y-%m-%d)"
}

own-recent() {
  if [ "${1:-}" = "-h" ]; then
    echo "List recently modified files (default: cwd, last 1 day)"
    echo "Usage: own-recent [path] [days]"
    return
  fi
  find "${1:-.}" -type f -mtime "-${2:-1}" -printf '%T+ %p\n' | sort -r
}
