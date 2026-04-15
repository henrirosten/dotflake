{ pkgs, ... }:
let
  gnomeFreezeDebug = pkgs.writeShellApplication {
    name = "gnome-freeze-debug";
    runtimeInputs = with pkgs; [
      gnugrep
      sudo
      systemd
    ];
    text = ''
      set -euo pipefail

      boot="''${1:--1}"

      if [ "$boot" = "-h" ] || [ "$boot" = "--help" ]; then
        cat <<'EOF'
      Usage: gnome-freeze-debug [BOOT]

      Collect useful logs for GNOME freezes.
      BOOT defaults to -1 (the previous boot), use 0 for current boot.
      EOF
        exit 0
      fi

      run_journalctl() {
        if [ "$EUID" -ne 0 ]; then
          if sudo -n true >/dev/null 2>&1; then
            sudo -n journalctl "$@"
          else
            journalctl "$@"
          fi
        else
          journalctl "$@"
        fi
      }

      run_coredumpctl() {
        if [ "$EUID" -ne 0 ]; then
          if sudo -n true >/dev/null 2>&1; then
            sudo -n coredumpctl "$@"
          else
            coredumpctl "$@"
          fi
        else
          coredumpctl "$@"
        fi
      }

      section() {
        printf "\n=== %s ===\n" "$1"
      }

      section "Kernel GPU and OOM signals (boot=$boot)"
      if ! run_journalctl -b "$boot" -k --no-pager | grep -Ei "i915|drm|gpu|hang|reset|lockup|oom"; then
        echo "No matching lines."
      fi

      section "GNOME stack signals (boot=$boot)"
      if ! run_journalctl -b "$boot" --no-pager | grep -Ei "gnome-shell|mutter|gdm|wayland|xorg|oomd"; then
        echo "No matching lines."
      fi

      section "Suspend and resume timeline (boot=$boot)"
      if ! run_journalctl -b "$boot" --no-pager | grep -Ei "suspend|resume|s2idle|deep|freeze|thaw"; then
        echo "No matching lines."
      fi

      section "Relevant coredumps (boot=$boot)"
      if ! run_coredumpctl list --boot "$boot" | grep -Ei "gnome-shell|mutter|xorg|gdm"; then
        echo "No matching lines."
      fi
    '';
  };

  gnomeFreezeWatchdog = pkgs.writeShellApplication {
    name = "gnome-freeze-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      glib
      gnugrep
      procps
      systemd
    ];
    text = ''
      set -euo pipefail

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/gnome-freeze-watchdog"
      mkdir -p "$state_dir"

      interval_sec="''${GNOME_WATCHDOG_INTERVAL_SEC:-5}"
      failure_threshold="''${GNOME_WATCHDOG_FAILURE_THRESHOLD:-6}"
      wedge_check_every="''${GNOME_WATCHDOG_WEDGE_CHECK_EVERY:-6}"
      failures=0
      seen_healthy=0
      wedge_reported=0
      loop_counter=0

      log() {
        echo "$1" | systemd-cat -t gnome-freeze-watchdog
      }

      ping_shell() {
        gdbus call \
          --session \
          --dest org.gnome.Shell \
          --object-path /org/gnome/Shell \
          --method org.freedesktop.DBus.Peer.Ping \
          --timeout 2 >/dev/null 2>&1
      }

      # A wedged i915 GPU leaves gnome-shell alive and D-Bus-responsive while
      # the display is frozen — the shell process happily produces frames
      # into a dead GPU (seen in the 2026-04-15 incident). The D-Bus ping
      # never fails, so we need a second signal to react to this failure
      # mode. The -g filter scopes to i915 kernel lines (which carry the
      # "i915 <pci>:" prefix), avoiding false positives from other DRM
      # drivers that reuse the same error wording.
      check_gpu_wedge() {
        journalctl -b -k --no-pager -g 'i915' 2>/dev/null |
          grep -qE "device wedged|Failed to reset chip"
      }

      collect_debug() {
        local ts="$1"
        local out="$state_dir/freeze-''${ts}.log"
        local rc=0

        /run/current-system/sw/bin/gnome-freeze-debug 0 >"$out" 2>&1 || rc=$?
        if [ "$rc" -ne 0 ]; then
          printf "\ngnome-freeze-debug exited with status %s\n" "$rc" >>"$out"
        fi

        printf "%s\n" "$out"
      }

      log "watchdog started (interval=$interval_sec, threshold=$failure_threshold)"

      while true; do
        # Periodic GPU-wedge check. If the kernel has logged a wedge during
        # this boot, D-Bus pings cannot represent the user-visible freeze.
        # Log once, surface a notification, and stop killing the session —
        # session-kill does not recover a wedged GPU, only a reboot does.
        if [ "$wedge_reported" -eq 0 ] &&
           [ $((loop_counter % wedge_check_every)) -eq 0 ] &&
           check_gpu_wedge; then
          ts="$(date +%Y%m%d-%H%M%S)"
          log_file="$(collect_debug "$ts")"
          {
            printf "time=%s\n" "$ts"
            printf "type=gpu-wedge\n"
            printf "session_id=%s\n" "''${XDG_SESSION_ID:-unknown}"
            printf "log=%s\n" "$log_file"
          } >"$state_dir/pending-notification"
          log "GPU wedge detected — session-kill cannot recover a wedged GPU; reboot required. Logs: $log_file"
          wedge_reported=1
        fi
        loop_counter=$((loop_counter + 1))

        if ping_shell; then
          seen_healthy=1
          failures=0
        elif [ "$wedge_reported" -eq 1 ]; then
          # GPU is already wedged; do not escalate to session-kill.
          :
        elif [ "$seen_healthy" -eq 1 ]; then
          failures=$((failures + 1))
          log "org.gnome.Shell ping failed ($failures/$failure_threshold)"

          if [ "$failures" -ge "$failure_threshold" ]; then
            ts="$(date +%Y%m%d-%H%M%S)"
            log_file="$(collect_debug "$ts")"

            {
              printf "time=%s\n" "$ts"
              printf "session_id=%s\n" "''${XDG_SESSION_ID:-unknown}"
              printf "log=%s\n" "$log_file"
            } > "$state_dir/pending-notification"

            log "freeze detected, logs saved to $log_file"

            if [ -n "''${XDG_SESSION_ID:-}" ]; then
              loginctl terminate-session "$XDG_SESSION_ID" || true
            fi

            pkill -KILL -x gnome-shell || true
            exit 0
          fi
        fi

        sleep "$interval_sec"
      done
    '';
  };

  gnomeFreezeWatchdogNotify = pkgs.writeShellApplication {
    name = "gnome-freeze-watchdog-notify";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      libnotify
      systemd
    ];
    text = ''
      set -euo pipefail

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/gnome-freeze-watchdog"
      marker="$state_dir/pending-notification"
      [ -s "$marker" ] || exit 0

      ts="$(sed -n 's/^time=//p' "$marker" | head -n1)"
      session_id="$(sed -n 's/^session_id=//p' "$marker" | head -n1)"
      log_file="$(sed -n 's/^log=//p' "$marker" | head -n1)"
      type="$(sed -n 's/^type=//p' "$marker" | head -n1)"

      title="GNOME session recovered after freeze"
      body="Recovered at $ts (session $session_id). Run gnome-freeze-debug -1. Log: $log_file"
      if [ "$type" = "gpu-wedge" ]; then
        title="GPU was wedged — reboot was required to recover"
        body="Detected at $ts (session $session_id). Captured diagnostics in /var/log/gpu-hang/. Watchdog log: $log_file"
      fi

      # Let the notification daemon fully initialize after login.
      sleep 8

      if notify-send --app-name "GNOME Freeze Watchdog" --urgency=critical \
        "$title" "$body"; then
        rm -f "$marker"
      else
        echo "failed to send recovery notification" | systemd-cat -t gnome-freeze-watchdog
      fi
    '';
  };
in
{
  environment.systemPackages = [ gnomeFreezeDebug ];

  systemd.user.services = {
    gnome-freeze-watchdog = {
      description = "Detect GNOME Shell hangs and recover the session";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${gnomeFreezeWatchdog}/bin/gnome-freeze-watchdog";
        Restart = "always";
        RestartSec = "5s";
      };
      environment = {
        GNOME_WATCHDOG_INTERVAL_SEC = "5";
        GNOME_WATCHDOG_FAILURE_THRESHOLD = "6";
      };
    };

    gnome-freeze-watchdog-notify = {
      description = "Notify user when GNOME watchdog recovered a freeze";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${gnomeFreezeWatchdogNotify}/bin/gnome-freeze-watchdog-notify";
      };
    };
  };
}
