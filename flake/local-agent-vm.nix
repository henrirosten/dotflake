{
  agentPackage,
  profile ? (import ./local-model-profiles.nix).laptop,
}:
{ lib, pkgs, ... }:
let
  inherit (profile) contextSize maxTokens;
  modelName = lib.toLower profile.name;
  model = pkgs.fetchurl profile.model;
  modelsConfig = pkgs.writeText "local-models.json" (
    builtins.toJSON {
      providers.dotflake = {
        baseUrl = "http://127.0.0.1:8080/v1";
        api = "openai-completions";
        apiKey = "local";
        models = [
          {
            id = modelName;
            name = "${profile.name} (local ${profile.quant})";
            reasoning = false;
            input = [ "text" ];
            contextWindow = contextSize;
            inherit maxTokens;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            inherit (profile) samplingParams;
          }
        ];
      };
    }
  );
  settingsConfig = pkgs.writeText "local-agent-settings.json" (
    builtins.toJSON {
      defaultProvider = "dotflake";
      defaultModel = modelName;
      defaultThinkingLevel = "off";
      compaction = {
        reserveTokens = maxTokens;
        keepRecentTokens = maxTokens;
      };
      branchSummary.reserveTokens = maxTokens;
      enableInstallTelemetry = false;
      enableAnalytics = false;
    }
  );
  vmPrompt = pkgs.writeText "local-agent-system-prompt.txt" ''
    You are running inside an isolated NixOS VM.
    Passwordless sudo is available for administrative commands needed to complete the task.
    The project is in /work.
  '';
  localAgent = pkgs.writeShellApplication {
    name = "local-agent";
    runtimeInputs = [
      pkgs.curl
      pkgs.coreutils
      pkgs.iproute2
    ];
    text = ''
      export PI_CODING_AGENT_DIR="$HOME/.local/share/dotflake/local-agent"
      export PI_OFFLINE=1
      install -d -m 700 "$PI_CODING_AGENT_DIR"
      install -m 600 ${modelsConfig} "$PI_CODING_AGENT_DIR/models.json"
      if [ ! -e "$PI_CODING_AGENT_DIR/settings.json" ]; then
        install -m 600 ${settingsConfig} "$PI_CODING_AGENT_DIR/settings.json"
      fi
      echo "Waiting for the local model..." >&2
      ready=0
      for _ in {1..120}; do
        if curl --silent --fail --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
          ready=1
          break
        fi
        sleep 1
      done
      if [ "$ready" -ne 1 ]; then
        echo "Local model did not start; inspect: journalctl -u local-model" >&2
        exit 1
      fi
      has_default_route() {
        [ -n "$(ip -4 route show default)" ] || [ -n "$(ip -6 route show default)" ]
      }
      network_interface=0
      for interface in /sys/class/net/*; do
        if [ -e "$interface" ] && [ "''${interface##*/}" != lo ]; then
          network_interface=1
          break
        fi
      done
      # NetworkManager can still be configuring DHCP after the model is ready.
      if [ "$network_interface" -eq 1 ] && ! has_default_route; then
        echo "Waiting up to 5 seconds for a default network route..." >&2
        for _ in {1..5}; do
          sleep 1
          if has_default_route; then
            break
          fi
        done
      fi
      # Refresh our default without replacing a user's own prompt file or symlink.
      vm_prompt=$(mktemp "$PI_CODING_AGENT_DIR/.vm-prompt.XXXXXX")
      trap 'rm -f "$vm_prompt"' EXIT
      cat ${vmPrompt} >"$vm_prompt"
      if has_default_route; then
        echo "A default network route is configured; external access is limited to filtered internet." >>"$vm_prompt"
      elif [ "$network_interface" -eq 1 ]; then
        echo "A network interface is present, but no default route is configured yet. Networking may still be starting; recheck routes before assuming internet access." >>"$vm_prompt"
      else
        echo "No default network route is configured; external networking is unavailable." >>"$vm_prompt"
      fi
      mv -f "$vm_prompt" "$PI_CODING_AGENT_DIR/dotflake-vm-prompt.md"
      trap - EXIT
      if [ ! -e "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md" ] && [ ! -L "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md" ]; then
        ln -s dotflake-vm-prompt.md "$PI_CODING_AGENT_DIR/APPEND_SYSTEM.md"
      fi
      exec ${lib.getExe agentPackage} --provider dotflake --model ${modelName} \
        --thinking off --no-extensions "$@"
    '';
  };
in
{
  # Preserve the agent VM's checkout/export workflow; add only guest software.
  environment.systemPackages = [
    localAgent
    pkgs.python3
    pkgs.nixfmt
  ];
  virtualisation.qemu.options = [ "-cpu host" ];
  system.autoUpgrade.enable = lib.mkForce false;
  services.openssh.enable = lib.mkForce false;

  systemd.services.local-model = {
    description = "Local ${profile.name} inference";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs (
        [
          "${pkgs.llama-cpp}/bin/llama-server"
          "--model"
          (toString model)
          "--alias"
          modelName
          "--ctx-size"
          (toString contextSize)
          "--parallel"
          "1"
          "--host"
          "127.0.0.1"
          "--port"
          "8080"
          "--offline"
          "--no-webui"
          "--no-agent"
          "--jinja"
          "--chat-template-kwargs"
          (builtins.toJSON { enable_thinking = false; })
        ]
        ++ lib.optionals (profile.threads != null) [
          "--threads"
          (toString profile.threads)
          "--threads-batch"
          (toString profile.threads)
        ]
      );
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      MemoryMax = profile.memoryMax;
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
