{
  username,
  homeDir,
  guestPackage,
}:
{ lib, pkgs, ... }:
{
  virtualisation = {
    qemu.options = [
      ''-virtfs local,path="$AUTH_VM_BOOTSTRAP_DIR",mount_tag=auth-bootstrap,security_model=none,readonly=on''
      ''-virtfs local,path="$AGENT_INBOX",mount_tag=agent-inbox,security_model=none,readonly=on''
      ''-virtfs local,path="$AGENT_OUTBOX",mount_tag=agent-outbox,security_model=none''
      ''-drive file="$AGENT_DATA_IMAGE",format=qcow2,if=virtio''
    ];
    fileSystems = {
      "/mnt/auth-bootstrap" = {
        device = "auth-bootstrap";
        fsType = "9p";
        neededForBoot = true;
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "msize=524288"
          "ro"
          "nosuid"
          "nodev"
          "noexec"
        ];
      };
      "${homeDir}" = {
        device = "/dev/disk/by-label/agent-data";
        fsType = "ext4";
        neededForBoot = true;
        options = [ "commit=1" ];
      };
      "/mnt/agent-inbox" = {
        device = "agent-inbox";
        fsType = "9p";
        neededForBoot = true;
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "cache=none"
          "ro"
          "nosuid"
          "nodev"
          "noexec"
        ];
      };
      "/mnt/agent-outbox" = {
        device = "agent-outbox";
        fsType = "9p";
        neededForBoot = true;
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "cache=none"
          "rw"
          "nosuid"
          "nodev"
          "noexec"
        ];
      };
    };
  };

  # QEMU's Ctrl-A x skips the guest shutdown; write data back within about a
  # second instead of 30, so it loses only the last few seconds.
  boot.kernel.sysctl = {
    "vm.dirty_expire_centisecs" = 100;
    "vm.dirty_writeback_centisecs" = 100;
  };
  environment.systemPackages = [ guestPackage ];
  systemd.tmpfiles.rules = [
    "d ${homeDir} 0700 ${username} users -"
    "L+ /work - - - - ${homeDir}/work"
  ];
  systemd.services."home-manager-${username}" = {
    wants = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [ homeDir ];
  };
  # Clone the host branch on first boot; later boots fetch the branch the
  # launcher just sent into host/<branch>.
  systemd.services.agent-init = {
    description = "Initialize or update the persistent agent checkout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "home-manager-${username}.service" ];
    after = [ "home-manager-${username}.service" ];
    before = [ "auth-bootstrap.service" ];
    unitConfig.RequiresMountsFor = [
      homeDir
      "/mnt/agent-inbox"
      "/mnt/agent-outbox"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      Environment = "HOME=${homeDir}";
    };
    script = ''
      if [ -e ${homeDir}/work ]; then
        ${guestPackage}/bin/agent-update ${homeDir}/work
      else
        ${guestPackage}/bin/agent-init ${homeDir}/work
      fi
    '';
  };
  systemd.services."serial-getty@ttyS0" = {
    wants = [ "auth-bootstrap.service" ];
    after = [ "auth-bootstrap.service" ];
  };
  environment.shellInit = lib.mkAfter ''
    if [ -z "''${COPILOT_GITHUB_TOKEN:-}" ] && [ -r /run/vm-copilot/token ]; then
      COPILOT_GITHUB_TOKEN="$(${pkgs.coreutils}/bin/cat /run/vm-copilot/token)"
      export COPILOT_GITHUB_TOKEN
    fi
  '';
  home-manager.users.${username}.programs = {
    starship.settings.custom.vm_indicator.command = lib.mkForce (
      pkgs.writeShellScript "vm-indicator" ''
        printf vm
        if [ -f "$HOME/.codex/auth.json" ]; then printf ' codex'; fi
        if [ -f "$HOME/.claude/.credentials.json" ]; then printf ' claude'; fi
        if [ -n "''${COPILOT_GITHUB_TOKEN:-}" ] || [ -r /run/vm-copilot/token ]; then
          printf ' copilot'
        fi
        printf '\n'
      ''
    );
    # Start shells in /work, then run the command passed with `--exec` once,
    # on the serial console only.
    bash.initExtra = lib.mkAfter ''
      if [ "$PWD" = "$HOME" ] && [ -d /work ]; then
        cd /work
      fi
      if [ -z "''${SSH_CONNECTION:-}" ] && [ -f /run/vm-exec/command ] && [ "$(tty 2>/dev/null)" = /dev/ttyS0 ]; then
        {
          read -r vm_exec_rows vm_exec_cols
          IFS= read -r vm_exec_term
          vm_exec_command="$(cat)"
        } </run/vm-exec/command
        rm -f /run/vm-exec/command
        if [ -n "$vm_exec_cols" ]; then
          stty rows "$vm_exec_rows" cols "$vm_exec_cols" 2>/dev/null || true
        fi
        if [ -n "$vm_exec_term" ] && infocmp "$vm_exec_term" >/dev/null 2>&1; then
          export TERM="$vm_exec_term"
        fi
        eval "$vm_exec_command"
        unset vm_exec_rows vm_exec_cols vm_exec_term vm_exec_command
      fi
    '';
  };
  systemd.services.auth-bootstrap = {
    description = "Copy auth credentials from bootstrap share";
    after = [ "agent-init.service" ];
    wants = [ "agent-init.service" ];
    unitConfig.RequiresMountsFor = [ homeDir ];
    # Finish before the console autologin so credentials and the --exec command
    # are in place.
    before = [
      "getty.target"
      "systemd-user-sessions.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/auth-bootstrap; then
        exit 0
      fi
      user_group="$(${pkgs.coreutils}/bin/id -gn ${username} 2>/dev/null || echo users)"
      replace=0
      [ ! -f /mnt/auth-bootstrap/replace-auth ] || replace=1

      # Codex auth
      if [ -f /mnt/auth-bootstrap/codex-auth.json ] && { [ ! -e ${homeDir}/.codex/auth.json ] || [ "$replace" -eq 1 ]; }; then
        ${pkgs.coreutils}/bin/install -d -m 0700 ${homeDir}/.codex
        ${pkgs.coreutils}/bin/install -m 0600 \
          /mnt/auth-bootstrap/codex-auth.json \
          ${homeDir}/.codex/auth.json
        ${pkgs.coreutils}/bin/chown ${username}:"$user_group" ${homeDir}/.codex ${homeDir}/.codex/auth.json
      fi

      # Claude Code auth
      if [ -f /mnt/auth-bootstrap/claude-credentials.json ]; then
        ${pkgs.coreutils}/bin/install -d -m 0700 ${homeDir}/.claude
        if [ ! -e ${homeDir}/.claude/.credentials.json ] || [ "$replace" -eq 1 ]; then
          ${pkgs.coreutils}/bin/install -m 0600 \
            /mnt/auth-bootstrap/claude-credentials.json \
            ${homeDir}/.claude/.credentials.json
        fi
        # Mark onboarding complete so claude skips the first-run wizard.
        if [ -f ${homeDir}/.claude.json ]; then
          ${pkgs.coreutils}/bin/cat ${homeDir}/.claude.json
        else
          echo '{}'
        fi | ${pkgs.jq}/bin/jq '.hasCompletedOnboarding = true' > ${homeDir}/.claude.json.tmp
        ${pkgs.coreutils}/bin/install -m 0600 ${homeDir}/.claude.json.tmp ${homeDir}/.claude.json
        ${pkgs.coreutils}/bin/rm ${homeDir}/.claude.json.tmp
        ${pkgs.coreutils}/bin/chown -R ${username}:"$user_group" ${homeDir}/.claude ${homeDir}/.claude.json
      fi

      # Copilot CLI auth (exported as COPILOT_GITHUB_TOKEN by shellInit)
      ${pkgs.coreutils}/bin/rm -f ${homeDir}/.copilot/vm-github-token
      if [ -f /mnt/auth-bootstrap/copilot-github-token ] && { [ ! -e /run/vm-copilot/token ] || [ "$replace" -eq 1 ]; }; then
        ${pkgs.coreutils}/bin/install -d -m 0700 /run/vm-copilot
        ${pkgs.coreutils}/bin/install -m 0600 \
          /mnt/auth-bootstrap/copilot-github-token \
          /run/vm-copilot/token
        ${pkgs.coreutils}/bin/chown ${username}:"$user_group" /run/vm-copilot /run/vm-copilot/token
      fi

      # One-shot console command from --exec (run by bash initExtra). The
      # marker lives on the system disk, which survives a guest reboot but is
      # recreated for each launch, so the command runs once per launch.
      if [ -f /mnt/auth-bootstrap/exec-command ] && [ ! -e /var/lib/agent-exec-done ]; then
        ${pkgs.coreutils}/bin/install -d -m 0700 /run/vm-exec
        ${pkgs.coreutils}/bin/install -m 0600 \
          /mnt/auth-bootstrap/exec-command \
          /run/vm-exec/command
        ${pkgs.coreutils}/bin/chown ${username}:"$user_group" /run/vm-exec /run/vm-exec/command
        ${pkgs.coreutils}/bin/touch /var/lib/agent-exec-done
      fi

      # Drop live host mount after bootstrap to reduce host interaction surface.
      if ${pkgs.util-linux}/bin/mountpoint -q /mnt/auth-bootstrap; then
        ${pkgs.util-linux}/bin/umount /mnt/auth-bootstrap || true
      fi
    '';
  };
}
