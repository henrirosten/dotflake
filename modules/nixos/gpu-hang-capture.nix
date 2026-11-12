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

      capture() (
        local ts="$1"
        local out_dir capture_status=0

        # Serialize automatic and manual reads/clears. A subshell releases
        # this lock even when a capture fails. Never reuse a directory:
        # repeated --once calls within a second must not overwrite evidence.
        exec 9>"$out_root/.capture.lock" || return 1
        if ! flock --wait 60 9; then
          log "Timed out waiting for another GPU capture" || true
          return 1
        fi
        out_dir="$(mktemp -d "$out_root/$ts.XXXXXX")" || return 1

        # Copy the i915 error state for every DRM card that has one.
        # These sysfs binary attributes report size zero even when a dump
        # exists. Read them rather than testing their size, and only clear
        # the kernel's copy after saving it successfully.
        for f in /sys/class/drm/card*/error; do
          [ -e "$f" ] || continue
          local card
          card="$(basename "$(dirname "$f")")"
          if timeout --kill-after=5s 30s cat "$f" >"$out_dir/$card-error.txt" &&
             [ -s "$out_dir/$card-error.txt" ]; then
            echo 1 >"$f" 2>/dev/null || true
          else
            capture_status=1
            mv "$out_dir/$card-error.txt" "$out_dir/$card-error.partial.txt" || return 1
            log "Failed to read $f; partial dump saved, kernel error state left uncleared" || true
          fi
        done

        journalctl -b -k --no-pager >"$out_dir/journal-kernel.txt" 2>/dev/null || capture_status=1
        journalctl -b --no-pager -n 5000 >"$out_dir/journal-recent.txt" 2>/dev/null || capture_status=1

        {
          printf 'GPU hang captured at %s\n' "$ts"
          printf '\n'
          printf 'Host:    %s\n' "$(uname -n)"
          printf 'Kernel:  %s\n' "$(uname -r)"
          printf 'Cmdline: '
          cat /proc/cmdline || return 1
          printf '\n'
          printf 'Files in this capture:\n'
          ls -la "$out_dir"
          printf '\n'
          printf 'Contents:\n'
          printf '  card*-error.txt     raw i915 GPU error state (registers, ring contents, context, batch)\n'
          printf '  journal-kernel.txt  full kernel journal for the affected boot\n'
          printf '  journal-recent.txt  last 5000 mixed userspace+kernel journal entries\n'
        } >"$out_dir/README.txt" || return 1

        # Normalize perms: dir 0750, files 0640, group systemd-journal. This
        # matches the sensitivity of the underlying journal content.
        chown -R root:systemd-journal "$out_dir" || return 1
        chmod 0750 "$out_dir" || return 1
        chmod 0640 "$out_dir"/* || return 1

        printf '%s\n' "$out_dir"
        if [ "$capture_status" -eq 0 ]; then
          log "GPU hang diagnostics saved to $out_dir" || true
        else
          log "GPU hang capture incomplete; available diagnostics saved to $out_dir" || true
        fi
        return "$capture_status"
      )

      # Allow a manual capture before rebooting an already-wedged machine.
      case "''${1:-}" in
        --once)
          capture "manual-$(date -u +%Y%m%d-%H%M%SZ)" || exit 1
          exit 0
          ;;
        "") ;;
        *)
          echo "Usage: gpu-hang-capture [--once]" >&2
          exit 2
          ;;
      esac

      # Startup scan: if the kernel has recently logged an i915 hang but we
      # were not yet running (service restart, late boot), capture it now so
      # we do not lose the evidence. Only runs once per service start;
      # restarts within this window may capture the same incident again.
      if journalctl -b -k --no-pager --since "5 min ago" -g 'i915' 2>/dev/null |
        grep -E "$i915_hang_re" >/dev/null; then
        ts="startup-$(date -u +%Y%m%d-%H%M%SZ)"
        if ! capture "$ts"; then
          log "Startup capture incomplete; continuing to watch for GPU hangs"
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
            if ! capture "$(date -u +%Y%m%d-%H%M%SZ)"; then
              log "Capture incomplete; continuing to watch for GPU hangs"
            fi
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
  # Writes a unique UTC-stamped directory under /var/log/gpu-hang/ on every
  # hang detected via the kernel journal. Each capture contains the raw
  # /sys/class/drm/card*/error dump (wiped on reboot if not captured) plus
  # the kernel journal for that boot. The directory persists across reboots
  # so a later debugging session can pick up where the wedged session left off.
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
