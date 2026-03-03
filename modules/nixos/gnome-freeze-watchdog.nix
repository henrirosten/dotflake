{ pkgs, ... }:
let
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
      failures=0
      seen_healthy=0

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
        if ping_shell; then
          seen_healthy=1
          failures=0
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

      # Let the notification daemon fully initialize after login.
      sleep 8

      if notify-send --app-name "GNOME Freeze Watchdog" --urgency=critical \
        "GNOME session recovered after freeze" \
        "Recovered at $ts (session $session_id). Run gnome-freeze-debug -1. Log: $log_file"; then
        rm -f "$marker"
      else
        echo "failed to send recovery notification" | systemd-cat -t gnome-freeze-watchdog
      fi
    '';
  };
in
{
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
