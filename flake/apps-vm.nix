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
                # The VM runs with `-display none` so tty1 is unused. Disable its
                # autovt to avoid a lastlog2.db lock race with the ttyS0 autologin.
                systemd.services."autovt@tty1".enable = lib.mkForce false;
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
                  description = "Mount optional host shares at /mnt/host-share";
                  after = [ "local-fs.target" ];
                  wants = [ "local-fs.target" ];
                  before = [ "getty.target" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    share_root=/mnt/host-share
                    share_state_dir=/run/vm-host-shares
                    share_list="$share_state_dir/paths"
                    user_group="$(${pkgs.coreutils}/bin/id -gn ${username} 2>/dev/null || echo users)"
                    mounted_any=0

                    ${pkgs.coreutils}/bin/mkdir -p "$share_root" "$share_state_dir"
                    ${pkgs.coreutils}/bin/rm -f "$share_list"

                    for tag in /sys/bus/virtio/drivers/9pnet_virtio/virtio*/mount_tag; do
                      [ -r "$tag" ] || continue

                      tag_name="$(${pkgs.coreutils}/bin/cat "$tag")"
                      case "$tag_name" in
                        host-share)
                          mount_path="$share_root"
                          ;;
                        host-share-*)
                          share_name="''${tag_name#host-share-}"
                          mount_path="$share_root/$share_name"
                          ${pkgs.coreutils}/bin/mkdir -p "$mount_path"
                          ;;
                        *)
                          continue
                          ;;
                      esac

                      if ! ${pkgs.util-linux}/bin/mountpoint -q "$mount_path"; then
                        ${pkgs.util-linux}/bin/mount -t 9p \
                          -o trans=virtio,version=9p2000.L,rw,msize=104857600,nosuid,nodev \
                          "$tag_name" "$mount_path"
                      fi

                      ${pkgs.coreutils}/bin/chown ${username}:"$user_group" "$mount_path" || true
                      printf '%s\n' "$mount_path" >> "$share_list"
                      mounted_any=1
                    done

                    if [ "$mounted_any" -eq 0 ]; then
                      ${pkgs.coreutils}/bin/rm -f "$share_list"
                    fi
                  '';
                };
                systemd.services."home-manager-${username}" = {
                  after = [ "host-share-mount.service" ];
                  wants = [ "host-share-mount.service" ];
                };
                environment.loginShellInit = lib.mkAfter ''
                  if [ "$USER" = "${username}" ] && [ -z "''${SSH_CONNECTION:-}" ]; then
                    tty_path="$(tty 2>/dev/null || true)"
                    share_list=/run/vm-host-shares/paths
                    case "$tty_path" in
                      /dev/tty1|/dev/ttyS0)
                        if [ -s "$share_list" ]; then
                          echo "Host-shared directories:"
                          while IFS= read -r share_path; do
                            [ -n "$share_path" ] || continue
                            echo "  $share_path"
                          done < "$share_list"
                        fi
                        ;;
                    esac
                  fi
                '';
                home-manager.users.${username} =
                  { lib, ... }:
                  {
                    home.activation.linkSharedVpnSecrets = lib.hm.dag.entryBetween [ "sops-nix" ] [ "writeBoundary" ] ''
                      share_root=/mnt/host-share
                      share_list=/run/vm-host-shares/paths
                      share_paths=()

                      cleanup_shared_link() {
                        target="$1"
                        [ -L "$target" ] || return 0

                        link_target="$(${pkgs.coreutils}/bin/readlink "$target" || true)"
                        case "$link_target" in
                          "$share_root" | "$share_root"/*)
                            ${pkgs.coreutils}/bin/rm -f "$target"
                            ;;
                        esac
                      }

                      if [ -r "$share_list" ]; then
                        mapfile -t share_paths < "$share_list"
                      elif ${pkgs.util-linux}/bin/mountpoint -q "$share_root"; then
                        share_paths=("$share_root")
                      fi

                      if [ "''${#share_paths[@]}" -eq 0 ]; then
                        cleanup_shared_link "${homeDir}/.config/dotflake/secrets/vpn.yaml"
                        cleanup_shared_link "${homeDir}/.config/sops/age/keys.txt"
                        exit 0
                      fi

                      link_if_shared() {
                        target="$1"
                        shift
                        source_path=""
                        for share_path in "''${share_paths[@]}"; do
                          for relative_path in "$@"; do
                            candidate="$share_path/$relative_path"
                            if [ -f "$candidate" ]; then
                              source_path="$candidate"
                              break 2
                            fi
                          done
                        done

                        if [ -z "$source_path" ]; then
                          cleanup_shared_link "$target"
                          return 0
                        fi

                        target_dir="$(${pkgs.coreutils}/bin/dirname "$target")"
                        ${pkgs.coreutils}/bin/mkdir -p "$target_dir"

                        if [ -e "$target" ] && [ ! -L "$target" ]; then
                          return 0
                        fi

                        ${pkgs.coreutils}/bin/ln -snf "$source_path" "$target"
                      }

                      link_if_shared \
                        "${homeDir}/.config/dotflake/secrets/vpn.yaml" \
                        "vpn.yaml" \
                        "dotflake/secrets/vpn.yaml" \
                        ".config/dotflake/secrets/vpn.yaml"

                      link_if_shared \
                        "${homeDir}/.config/sops/age/keys.txt" \
                        "keys.txt" \
                        "sops/age/keys.txt" \
                        ".config/sops/age/keys.txt"
                    '';
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
