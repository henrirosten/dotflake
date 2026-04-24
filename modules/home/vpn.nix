{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  coreutils = pkgs.coreutils;
  jq = lib.getExe pkgs.jq;
  openconnect = lib.getExe pkgs.openconnect;
  openfortivpn = lib.getExe pkgs.openfortivpn;
  openvpn = lib.getExe pkgs.openvpn;
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  localSopsFile = config.lib.file.mkOutOfStoreSymlink "${config.xdg.configHome}/dotflake/secrets/vpn.yaml";
in
{
  imports = [ inputs.sops-nix.homeManagerModules.sops ];

  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = localSopsFile;
    defaultSopsFormat = "yaml";
    validateSopsFiles = false;

    secrets.vpn-profiles = {
      path = "%r/vpn/profiles.json";
      mode = "0600";
    };
  };

  home.packages = [
    pkgs.age
    pkgs.sops
    (pkgs.writeShellApplication {
      name = "vpn";
      text = ''
        set -euo pipefail

        profiles_path_template='${config.sops.secrets.vpn-profiles.path}'
        source_sops_file='${config.xdg.configHome}/dotflake/secrets/vpn.yaml'
        age_key_file='${config.home.homeDirectory}/.config/sops/age/keys.txt'
        runtime_dir="''${XDG_RUNTIME_DIR:-}"

        if [ -z "$runtime_dir" ]; then
          echo "XDG_RUNTIME_DIR is not set." >&2
          exit 1
        fi

        profiles_path="''${profiles_path_template//%r/$runtime_dir}"

        usage() {
          echo "Usage: vpn list | vpn <profile>" >&2
        }

        ensure_profiles() {
          if [ -f "$profiles_path" ]; then
            return 0
          fi

          if [ ! -f "$source_sops_file" ] || [ ! -f "$age_key_file" ]; then
            return 1
          fi

          if ${systemctl} --user start sops-nix.service >/dev/null 2>&1; then
            for _ in $("${coreutils}/bin/seq" 1 20); do
              if [ -f "$profiles_path" ]; then
                return 0
              fi
              ${coreutils}/bin/sleep 0.1
            done
          fi

          [ -f "$profiles_path" ]
        }

        resolve_client() {
          case "$1" in
            openconnect) printf '%s\n' '${openconnect}' ;;
            openfortivpn) printf '%s\n' '${openfortivpn}' ;;
            openvpn) printf '%s\n' '${openvpn}' ;;
            *)
              echo "Unsupported VPN client '$1'." >&2
              exit 1
              ;;
          esac
        }

        if ! ensure_profiles; then
          echo "Missing VPN profiles at $profiles_path." >&2
          echo "Make sure $source_sops_file and $age_key_file are present." >&2
          echo "In a VM, share either vpn.yaml + keys.txt or the host-style dotflake/secrets + sops/age layout." >&2
          exit 1
        fi

        if [ $# -eq 1 ] && [ "$1" = "list" ]; then
          ${jq} -r '.profiles[].name' "$profiles_path"
          exit 0
        fi

        if [ $# -ne 1 ]; then
          usage
          exit 1
        fi

        profile_name="$1"
        profile_json="$(${jq} -ce --arg name "$profile_name" 'first(.profiles[] | select(.name == $name))' "$profiles_path")" || {
          echo "Unknown VPN profile '$profile_name'." >&2
          echo "Run 'vpn list' after secrets are available." >&2
          exit 1
        }

        client="$(printf '%s' "$profile_json" | ${jq} -r '.client')"
        binary="$(resolve_client "$client")"
        use_sudo="$(printf '%s' "$profile_json" | ${jq} -r '.sudo // true')"
        config_file=""

        cleanup() {
          if [ -n "$config_file" ]; then
            rm -f "$config_file"
          fi
        }
        trap cleanup EXIT

        if printf '%s' "$profile_json" | ${jq} -e '.config != null' >/dev/null; then
          config_file="$(mktemp)"
          chmod 600 "$config_file"
          printf '%s' "$profile_json" | ${jq} -r '.config' > "$config_file"
        fi

        mapfile -t argv < <(printf '%s' "$profile_json" | ${jq} -r '.argv[]')
        if [ "''${#argv[@]}" -eq 0 ]; then
          echo "VPN profile '$profile_name' has no argv." >&2
          exit 1
        fi

        for i in "''${!argv[@]}"; do
          if [ "''${argv[i]}" = "__CONFIG__" ]; then
            if [ -z "$config_file" ]; then
              echo "VPN profile '$profile_name' expects an inline config." >&2
              exit 1
            fi
            argv[i]="$config_file"
          fi
        done

        if [ "$use_sudo" = "true" ]; then
          exec sudo "$binary" "''${argv[@]}"
        fi

        exec "$binary" "''${argv[@]}"
      '';
    })
  ];
}
