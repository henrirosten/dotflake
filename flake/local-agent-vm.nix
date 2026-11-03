{ agentPackage }:
{ lib, pkgs, ... }:
let
  modelName = "qwen3.5-4b";
  contextSize = 8192;
  model = pkgs.fetchurl {
    name = "Qwen3.5-4B-Q5_K_M.gguf";
    url = "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q5_K_M.gguf";
    sha256 = "8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39";
  };
  modelsConfig = pkgs.writeText "local-models.json" (
    builtins.toJSON {
      providers.dotflake = {
        baseUrl = "http://127.0.0.1:8080/v1";
        api = "openai-completions";
        apiKey = "local";
        models = [
          {
            id = modelName;
            name = "Qwen3.5-4B (local Q5_K_M)";
            reasoning = false;
            input = [ "text" ];
            contextWindow = contextSize;
            maxTokens = 2048;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            samplingParams = {
              temperature = 0.7;
              top_p = 0.8;
              top_k = 20;
              presence_penalty = 1.5;
              chat_template_kwargs.enable_thinking = false;
            };
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
        reserveTokens = 2048;
        keepRecentTokens = 2048;
      };
      branchSummary.reserveTokens = 2048;
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
    description = "Local Qwen3.5-4B inference";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
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
      ];
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
      MemoryMax = "75%";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
