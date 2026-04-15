{ pkgs, ... }:
let
  gpuHangCapture = pkgs.writeShellApplication {
    name = "gpu-hang-capture";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      # Captures contain register state, ring buffers, and journal excerpts.
      # Match journald's access model: readable by members of the
      # systemd-journal group, sudo otherwise. Umask tightens default perms
      # for anything we redirect or mkdir.
      umask 027

      out_root="/var/log/gpu-hang"
      mkdir -p "$out_root"

      # Kernel journal lines from i915 are prefixed with "i915 <pci>:"; this
      # filter keeps us from reacting to other DRM drivers that happen to
      # share substrings (amdgpu/nouveau/xe).
      i915_hang_re="GPU HANG|device wedged|Failed to reset chip"

      log() {
        echo "$1" | systemd-cat -t gpu-hang-capture -p warning
      }

      capture() {
        local ts="$1"
        local out_dir="$out_root/$ts"
        mkdir -p "$out_dir"

        # Copy the i915 error state for every DRM card that has one.
        # /sys/class/drm/card*/error is always present but only non-empty
        # after a GPU hang; writing "1" clears it so the next hang produces
        # a fresh dump.
        for f in /sys/class/drm/card*/error; do
          [ -e "$f" ] || continue
          if [ -s "$f" ]; then
            local card
            card="$(basename "$(dirname "$f")")"
            cp "$f" "$out_dir/$card-error.txt"
            echo 1 >"$f" 2>/dev/null || true
          fi
        done

        journalctl -b -k --no-pager >"$out_dir/journal-kernel.txt" 2>/dev/null || true
        journalctl -b --no-pager -n 5000 >"$out_dir/journal-recent.txt" 2>/dev/null || true

        {
          printf 'GPU hang captured at %s\n' "$ts"
          printf '\n'
          printf 'Host:    %s\n' "$(uname -n)"
          printf 'Kernel:  %s\n' "$(uname -r)"
          printf 'Cmdline: '
          cat /proc/cmdline
          printf '\n'
          printf 'Files in this capture:\n'
          ls -la "$out_dir"
          printf '\n'
          printf 'Contents:\n'
          printf '  card*-error.txt     raw i915 GPU error state (registers, ring contents, context, batch)\n'
          printf '  journal-kernel.txt  full kernel journal for the affected boot\n'
          printf '  journal-recent.txt  last 5000 mixed userspace+kernel journal entries\n'
        } >"$out_dir/README.txt"

        # Normalize perms: dir 0750, files 0640, group systemd-journal. This
        # matches the sensitivity of the underlying journal content.
        chown -R root:systemd-journal "$out_dir"
        chmod 0750 "$out_dir"
        chmod 0640 "$out_dir"/*

        log "GPU hang diagnostics saved to $out_dir"
      }

      # Startup scan: if the kernel has recently logged an i915 hang but we
      # were not yet running (service restart, late boot), capture it now so
      # we do not lose the evidence. Only runs once per service start.
      if journalctl -b -k --no-pager --since "5 min ago" -g 'i915' 2>/dev/null |
        grep -qE "$i915_hang_re"; then
        ts="startup-$(date -u +%Y%m%d-%H%M%SZ)"
        if [ ! -d "$out_root/$ts" ]; then
          capture "$ts"
        fi
      fi

      log "watcher started"

      last_capture=0

      # Follow the kernel log live, pre-filtered to i915 lines, and react to
      # hang markers. A single incident emits several of these lines
      # back-to-back; the 60-second cooldown coalesces them into one capture
      # directory.
      while IFS= read -r line; do
        case "$line" in
          *"GPU HANG"* | *"device wedged"* | *"Failed to reset chip"*)
            now="$(date +%s)"
            if [ $((now - last_capture)) -lt 60 ]; then
              continue
            fi
            last_capture="$now"
            # Brief delay so the kernel finishes writing /sys/class/drm/card*/error
            # before we copy it.
            sleep 2
            capture "$(date -u +%Y%m%d-%H%M%SZ)"
            ;;
        esac
      done < <(journalctl -fkn0 --no-pager -g 'i915' 2>/dev/null)
    '';
  };
in
{
  environment.systemPackages = [ gpuHangCapture ];

  systemd.tmpfiles.rules = [
    "d /var/log/gpu-hang 0750 root systemd-journal - -"
  ];

  # Persistent capture of i915 GPU hang diagnostics.
  #
  # Writes /var/log/gpu-hang/<UTC-timestamp>/ on every hang detected via the
  # kernel journal. Each capture contains the raw /sys/class/drm/card*/error
  # dump (wiped on reboot if not captured) plus the kernel journal for that
  # boot. The directory persists across reboots so a later debugging session
  # can pick up where the wedged session left off.
  systemd.services.gpu-hang-capture = {
    description = "Capture i915 GPU hang diagnostics to /var/log/gpu-hang/";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-journald.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${gpuHangCapture}/bin/gpu-hang-capture";
      Restart = "always";
      RestartSec = "10s";
    };
  };
}
