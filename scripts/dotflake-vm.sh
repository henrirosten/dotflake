#!/usr/bin/env bash
set -euo pipefail
umask 077

ram_mb=8192
cpus=2
project=.
instance=default
guest_exec=""
declare -A auth=()
auth_replace=0
instance_dir=""
auth_bootstrap_dir=""
runner_pid=""
tmp_raw=""
agent_locked=0

for variable in VM_HOST_SHARE_DIR VM_HOST_SHARE_DIRS NIX_DISK_IMAGE QEMU_OPTS; do
  if [[ -v $variable ]]; then
    echo "$variable is not supported by dotflake-vm" >&2
    exit 2
  fi
done

while [ "$#" -gt 0 ]; do
  case "$1" in
  --project | --instance | --auth | --exec | --ram-mb | --cpus)
    case "${2:-}" in
    "" | -*)
      echo "Invalid or missing value for $1" >&2
      exit 2
      ;;
    esac
    case "$1" in
    --project) project=$2 ;;
    --instance) instance=$2 ;;
    --exec) guest_exec=$2 ;;
    --ram-mb) ram_mb=$2 ;;
    --cpus) cpus=$2 ;;
    --auth)
      provider=${2%%=*}
      case "$provider" in
      codex | claude | copilot) auth[$provider]=$2 ;;
      *)
        echo "Unknown auth provider: $2" >&2
        exit 2
        ;;
      esac
      ;;
    esac
    shift 2
    ;;
  --auth-replace)
    auth_replace=1
    shift
    ;;
  --help | -h)
    cat <<'EOF'
Usage: dotflake-vm [--instance NAME] [--project PATH] [OPTIONS]
  --instance NAME  Instance to start, created on first use
                   (per project; default: default)
  --project PATH   Git repository the agent works on
                   (default: the repository containing the current directory)
  --auth PROVIDER[=FILE]
                   Provision codex, claude or copilot (repeatable; default: none)
  --auth-replace   Replace existing guest credentials for selected providers
  --exec CMD       Run CMD on the console after boot
  --ram-mb MB      RAM in MiB (default: 8192)
  --cpus N         Number of CPUs (default: 2)
Each launch sends the project's current branch; the guest fetches it into
host/<branch> at boot. The persistent data disk is 32 GiB. Shut down with
sudo poweroff: Ctrl-A x skips the guest shutdown and can lose recent writes.
Credentials persist until deleted in the guest or with dotflake-agent
discard. Copilot bootstrap tokens live under /run.
Without FILE: codex uses ${CODEX_HOME:-$HOME/.codex}/auth.json;
claude uses ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json;
copilot uses COPILOT_GITHUB_TOKEN, then the copilot-cli keyring entry.
FILE may start with ~/ or name a pipe; Copilot files contain a token.
For repeated providers, the last --auth wins. Missing defaults are skipped.
EOF
    exit 0
    ;;
  *)
    echo "Unknown option or runner argument: $1" >&2
    exit 2
    ;;
  esac
done

if ! [[ $ram_mb =~ ^[1-9][0-9]*$ && $cpus =~ ^[1-9][0-9]*$ ]]; then
  echo "RAM and CPU counts must be positive integers" >&2
  exit 2
fi

# Validate explicit sources before resolving instance paths or preparing state.
for provider in "${!auth[@]}"; do
  case "${auth[$provider]}" in
  codex) file="${CODEX_HOME:-$HOME/.codex}/auth.json" ;;
  claude) file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ;;
  copilot) file="" ;;
  *)
    file=${auth[$provider]#*=}
    [[ $file != \~/* ]] || file="$HOME/${file:2}"
    if [[ ! -r $file || -d $file ]]; then
      echo "--auth $provider: not a readable file: $file" >&2
      exit 2
    fi
    ;;
  esac
  auth[$provider]=$file
done

cleanup() {
  status="$?"
  trap - EXIT INT TERM
  if [ -n "$runner_pid" ]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  if [ -n "$auth_bootstrap_dir" ]; then
    for f in "$auth_bootstrap_dir"/codex-auth.json "$auth_bootstrap_dir"/claude-credentials.json "$auth_bootstrap_dir"/copilot-github-token; do
      if [ -f "$f" ]; then
        shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
      fi
    done
    rm -rf -- "$auth_bootstrap_dir"
  fi
  if [ "$agent_locked" -eq 1 ]; then
    rm -f -- "$instance_dir/system.qcow2" "$instance_dir/gcroot" "$instance_dir/.data.tmp"
  fi
  [ -z "$tmp_raw" ] || rm -f -- "$tmp_raw"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

layout=$(dotflake-agent paths --project "$project" --instance "$instance")
instance_dir=$(jq -r .directory <<<"$layout")
instance_lock=$(jq -r .lock <<<"$layout")
exec 9>"$instance_lock"
if ! flock -n 9; then
  echo "Instance is already running: $instance" >&2
  exit 1
fi
agent_locked=1
disk_image="$instance_dir/system.qcow2"
export AGENT_INBOX AGENT_OUTBOX AGENT_DATA_IMAGE
AGENT_INBOX=$(jq -r .inbox <<<"$layout")
AGENT_OUTBOX=$(jq -r .outbox <<<"$layout")
AGENT_DATA_IMAGE="$instance_dir/data.qcow2"
# discard can win between resolving paths and taking the permanent lock.
mkdir -p -- "$AGENT_INBOX" "$AGENT_OUTBOX"
rm -f -- "$instance_dir/gcroot" "$disk_image" "$instance_dir/.data.tmp"
rm -rf -- "$instance_dir/auth-bootstrap"
# Send the current branch on every launch; the guest fetches it at boot.
if ! dotflake-agent push --project "$project" --instance "$instance"; then
  [ -f "$AGENT_INBOX/host.bundle" ] || exit 1
  echo "Note: the guest keeps the previously sent branch" >&2
fi
vm_store="@vmRunner@"
nix-store --realise "${vm_store%/bin/*}" --add-root "$instance_dir/gcroot" --indirect >/dev/null
if [ ! -f "$AGENT_DATA_IMAGE" ]; then
  tmp_raw=$(@mktemp@ -p "$instance_dir" .data.XXXXXX.raw)
  @qemuImg@ create -f raw "$tmp_raw" 32G
  @mkfsExt4@ -L agent-data "$tmp_raw" >/dev/null
  @qemuImg@ convert -f raw -O qcow2 "$tmp_raw" "$instance_dir/.data.tmp"
  mv -- "$instance_dir/.data.tmp" "$AGENT_DATA_IMAGE"
  rm -f -- "$tmp_raw"
  tmp_raw=""
fi

auth_bootstrap_dir="$instance_dir/auth-bootstrap"
mkdir -m 700 -- "$auth_bootstrap_dir"
if [ "$auth_replace" -eq 1 ]; then
  touch "$auth_bootstrap_dir/replace-auth"
fi
for provider in "${!auth[@]}"; do
  file=${auth[$provider]}
  case "$provider" in
  codex) target=codex-auth.json ;;
  claude) target=claude-credentials.json ;;
  copilot)
    if [ -n "$file" ]; then
      copilot_token=$(cat <"$file")
    elif [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
      copilot_token=$COPILOT_GITHUB_TOKEN
    else
      copilot_token=$(@secretTool@ lookup service copilot-cli 2>/dev/null || true)
    fi
    copilot_token="${copilot_token//[[:space:]]/}"
    if [ -n "$copilot_token" ]; then
      printf '%s\n' "$copilot_token" >"$auth_bootstrap_dir/copilot-github-token"
    else
      echo "Note: no Copilot CLI token found, Copilot in the VM will not be logged in (see --auth in --help)" >&2
    fi
    unset copilot_token
    continue
    ;;
  esac
  if [[ -r $file && ! -d $file ]]; then
    cat <"$file" >"$auth_bootstrap_dir/$target"
  else
    echo "Note: no $provider credentials found (see --auth in --help)" >&2
  fi
done
if [ -n "$guest_exec" ]; then
  # Line 1: host terminal rows and columns, line 2: TERM, rest: the command.
  {
    stty size 2>/dev/null </dev/tty || echo
    printf '%s\n' "${TERM:-}"
    printf '%s\n' "$guest_exec"
  } >"$auth_bootstrap_dir/exec-command"
fi

export AUTH_VM_BOOTSTRAP_DIR="$auth_bootstrap_dir"
export NIX_DISK_IMAGE="$disk_image"
export QEMU_OPTS="-m $ram_mb -smp $cpus"
"@vmRunner@" <&0 &
runner_pid=$!
wait "$runner_pid"
