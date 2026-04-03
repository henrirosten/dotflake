{
  inputs,
  forAllSystems,
  mkPkgs,
  nixosConfigurations,
}:
forAllSystems (
  system:
  let
    lib = inputs.nixpkgs.lib;
    pkgs = mkPkgs system;
    hrosten = import ../users/hrosten/hrosten.nix;
    username = hrosten.user.username;
    homeDir = hrosten.user.homedir;
    sameSystemNixosConfigurations = lib.filterAttrs (
      _: nixosConfig: nixosConfig.pkgs.stdenv.hostPlatform.system == system
    ) nixosConfigurations;
  in
  lib.mapAttrs' (
    name: nixosConfig:
    let
      isGeneric = name == "generic";
      vcpus = if isGeneric then 4 else 1;
      ramGb = if isGeneric then 16 else 1;
      diskGb = if isGeneric then 100 else 8;
      vmConfig = nixosConfig.extendModules {
        modules = [
          (
            { lib, ... }:
            lib.mkMerge [
              {
                virtualisation.vmVariant = {
                  virtualisation = {
                    graphics = lib.mkForce true;
                    cores = lib.mkForce vcpus;
                    memorySize = lib.mkForce (ramGb * 1024);
                    diskSize = lib.mkForce (diskGb * 1024);
                    writableStore = lib.mkForce true;
                    useNixStoreImage = lib.mkForce false;
                    mountHostNixStore = lib.mkForce true;
                    writableStoreUseTmpfs = lib.mkForce false;
                    restrictNetwork = lib.mkForce false;
                    forwardPorts = [
                      {
                        from = "host";
                        host.address = "127.0.0.1";
                        host.port = 2222;
                        guest.port = 22;
                      }
                    ];
                    qemu.consoles = lib.mkForce [ "ttyS0,115200n8" ];
                    qemu.options = lib.mkAfter ([
                      "-display none"
                      "-serial mon:stdio"
                      "-device virtio-balloon"
                      "-enable-kvm"
                      # Ask QEMU to self-restrict host-side capabilities.
                      "-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"
                    ]);
                    sharedDirectories =
                      if isGeneric then
                        lib.mkForce {
                          nix-store = {
                            source = builtins.storeDir;
                            target = "/nix/.ro-store";
                            securityModel = "none";
                          };
                          # Keep only bootstrap auth as a transient host share.
                          auth-bootstrap = {
                            # One-way bootstrap source prepared by run-vm.sh.
                            source = ''"''${AUTH_VM_BOOTSTRAP_DIR:-$TMPDIR/xchg}"'';
                            target = "/mnt/auth-bootstrap";
                            securityModel = "none";
                          };
                        }
                      else
                        { };
                  };
                };
                services.getty.autologinUser = lib.mkForce username;
                services.openssh.settings.X11Forwarding = lib.mkForce true;
                programs.ssh.setXAuthLocation = lib.mkForce true;
                # Keep VM boot logs deterministic for CI/smoke runs: auditd emits
                # spurious startup errors in these ephemeral QEMU guests and we do
                # not rely on kernel audit trails inside test VMs.
                security.audit.enable = lib.mkForce false;
                security.auditd.enable = lib.mkForce false;
                # Laptop-oriented throttling service can fail in QEMU guests and
                # cause degraded boot state; keep it disabled in VM variants.
                services.throttled.enable = lib.mkForce false;
                security.sudo.wheelNeedsPassword = lib.mkForce false;
                # Disable systemd-ssh-generator auto sockets to avoid AF_VSOCK probe errors in VM logs.
                boot.kernelParams = lib.mkAfter [ "systemd.ssh_auto=0" ];
                # VM-friendly free-space thresholds to avoid activation stalls
                # with tmpfs-backed writable store overlays.
                nix.settings = {
                  min-free = lib.mkForce (128 * 1024 * 1024);
                  max-free = lib.mkForce (512 * 1024 * 1024);
                };
                systemd.tmpfiles.rules = [
                  "d /mnt/host-share 0755 ${username} users -"
                ]
                ++ lib.optionals isGeneric [
                  "d /mnt/auth-bootstrap 0755 root root -"
                ];
                systemd.services.host-share-mount = {
                  description = "Mount optional host share at /mnt/host-share";
                  after = [ "local-fs.target" ];
                  wants = [ "local-fs.target" ];
                  before = [ "getty.target" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    if ${pkgs.util-linux}/bin/mountpoint -q /mnt/host-share; then
                      exit 0
                    fi

                    for tag in /sys/bus/virtio/drivers/9pnet_virtio/virtio*/mount_tag; do
                      if [ -r "$tag" ] && [ "$(${pkgs.coreutils}/bin/cat "$tag")" = "host-share" ]; then
                        ${pkgs.util-linux}/bin/mount -t 9p \
                          -o trans=virtio,version=9p2000.L,rw,msize=104857600,nosuid,nodev \
                          host-share /mnt/host-share
                        user_group="$(${pkgs.coreutils}/bin/id -gn ${username} 2>/dev/null || echo users)"
                        ${pkgs.coreutils}/bin/chown ${username}:"$user_group" /mnt/host-share || true
                        exit 0
                      fi
                    done
                  '';
                };
                environment.loginShellInit = lib.mkAfter ''
                  if [ "$USER" = "${username}" ] && [ -z "''${SSH_CONNECTION:-}" ]; then
                    tty_path="$(tty 2>/dev/null || true)"
                    case "$tty_path" in
                      /dev/tty1|/dev/ttyS0)
                        if ${pkgs.util-linux}/bin/mountpoint -q /mnt/host-share; then
                          cd /mnt/host-share || true
                        fi
                        ;;
                    esac
                  fi
                '';
                home-manager.users.${username} = {
                  programs.starship.settings = {
                    format = lib.mkForce "\${custom.vm_indicator}$all";
                    custom.vm_indicator = {
                      when = true;
                      command = "echo vm";
                      format = "[[$output](bold yellow)]($style) ";
                      style = "bold yellow";
                    };
                  };
                };
              }
              (lib.optionalAttrs isGeneric {
                # Keep bootstrap share read-only and non-executable in guest.
                fileSystems."/mnt/auth-bootstrap".options = lib.mkAfter [
                  "ro"
                  "nosuid"
                  "nodev"
                  "noexec"
                ];
                systemd.services.auth-bootstrap = {
                  description = "Copy auth credentials from bootstrap share";
                  after = [ "local-fs.target" ];
                  wants = [ "local-fs.target" ];
                  before = [ "getty.target" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/auth-bootstrap; then
                      exit 0
                    fi
                    user_group="$(${pkgs.coreutils}/bin/id -gn ${username} 2>/dev/null || echo users)"

                    # Codex auth
                    if [ -f /mnt/auth-bootstrap/codex-auth.json ]; then
                      ${pkgs.coreutils}/bin/install -d -m 0700 ${homeDir}/.codex
                      ${pkgs.coreutils}/bin/install -m 0600 \
                        /mnt/auth-bootstrap/codex-auth.json \
                        ${homeDir}/.codex/auth.json
                      ${pkgs.coreutils}/bin/chown ${username}:"$user_group" ${homeDir}/.codex ${homeDir}/.codex/auth.json
                      ${pkgs.coreutils}/bin/rm -f /mnt/auth-bootstrap/codex-auth.json || true
                    fi

                    # Claude Code auth
                    if [ -f /mnt/auth-bootstrap/claude-credentials.json ]; then
                      ${pkgs.coreutils}/bin/install -d -m 0700 ${homeDir}/.claude
                      ${pkgs.coreutils}/bin/install -m 0600 \
                        /mnt/auth-bootstrap/claude-credentials.json \
                        ${homeDir}/.claude/.credentials.json
                      if [ -f /mnt/auth-bootstrap/claude-settings.json ]; then
                        ${pkgs.coreutils}/bin/install -m 0600 \
                          /mnt/auth-bootstrap/claude-settings.json \
                          ${homeDir}/.claude/settings.json
                      fi
                      # Mark onboarding complete so claude skips the first-run wizard.
                      echo '{"hasCompletedOnboarding":true}' \
                        | ${pkgs.coreutils}/bin/install -m 0600 /dev/stdin ${homeDir}/.claude.json
                      ${pkgs.coreutils}/bin/chown -R ${username}:"$user_group" ${homeDir}/.claude ${homeDir}/.claude.json
                      ${pkgs.coreutils}/bin/rm -f /mnt/auth-bootstrap/claude-credentials.json /mnt/auth-bootstrap/claude-settings.json || true
                    fi

                    # Drop live host mount after bootstrap to reduce host interaction surface.
                    if ${pkgs.util-linux}/bin/mountpoint -q /mnt/auth-bootstrap; then
                      ${pkgs.util-linux}/bin/umount /mnt/auth-bootstrap || true
                    fi
                  '';
                };
              })
            ]
          )
        ];
      };
      vmRunner = "${vmConfig.config.virtualisation.vmVariant.system.build.vm}/bin/run-${name}-vm";
      vmAppRunner = pkgs.replaceVarsWith {
        src = ../scripts/run-vm.sh;
        name = "run-${name}-vm";
        dir = "bin";
        isExecutable = true;
        replacements = {
          vmName = name;
          defaultRamMb = toString (ramGb * 1024);
          defaultCpus = toString vcpus;
          defaultDiskSize = "${toString diskGb}G";
          defaultDiskImage = "./${name}.qcow2";
          defaultCleanupDisk = "1";
          bootstrapAuth = if isGeneric then "1" else "0";
          mktemp = "${pkgs.coreutils}/bin/mktemp";
          qemuImg = "${pkgs.qemu}/bin/qemu-img";
          mkfsExt4 = "${pkgs.e2fsprogs}/bin/mkfs.ext4";
          inherit vmRunner;
        };
      };
    in
    lib.nameValuePair "${name}-vm" {
      type = "app";
      program = "${vmAppRunner}/bin/run-${name}-vm";
      meta = {
        description = "Run ${name} VM - 'nix run .#${name}-vm -- --help'";
      };
    }
  ) sameSystemNixosConfigurations
)
