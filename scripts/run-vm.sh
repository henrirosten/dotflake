#!/usr/bin/env bash

cleanup_disk=@defaultCleanupDisk@
bootstrap_auth=@bootstrapAuth@
ram_mb="@defaultRamMb@"
cpus="@defaultCpus@"
disk_size="@defaultDiskSize@"
disk_image="${NIX_DISK_IMAGE:-@defaultDiskImage@}"
host_codex_auth_file="${CODEX_HOST_AUTH_FILE:-$HOME/.codex/auth.json}"
host_claude_auth_file="${CLAUDE_HOST_AUTH_FILE:-$HOME/.claude/.credentials.json}"
host_share_dir="${VM_HOST_SHARE_DIR:-}"
host_share_dirs_env="${VM_HOST_SHARE_DIRS:-}"
declare -a host_share_dirs=()
declare -a host_share_names=()
managed_auth_bootstrap_dir=0
auth_bootstrap_dir=""
override_ram=0
override_cpus=0
override_disk_size=0
use_cli_share_dirs=0

umask 077

if [ -n "$host_share_dirs_env" ]; then
  IFS=: read -r -a host_share_dirs <<<"$host_share_dirs_env"
elif [ -n "$host_share_dir" ]; then
  host_share_dirs=("$host_share_dir")
fi

share_name_in_use() {
  local name="$1"
  local existing

  for existing in "${host_share_names[@]}"; do
    if [ "$existing" = "$name" ]; then
      return 0
    fi
  done

  return 1
}

derive_share_name() {
  local dir="$1"
  local name="${dir##*/}"
  local base
  local suffix

  while [ -n "$name" ] && [ "${name#.}" != "$name" ]; do
    name="${name#.}"
  done

  name="${name//[^[:alnum:]._-]/-}"
  while [[ $name == *--* ]]; do
    name="${name//--/-}"
  done
  name="${name#-}"
  name="${name%-}"

  if [ -z "$name" ]; then
    name="share"
  fi

  base="$name"
  suffix=2
  while share_name_in_use "$name"; do
    name="${base}-${suffix}"
    suffix=$((suffix + 1))
  done

  printf '%s\n' "$name"
}

validate_share_dir() {
  local dir="$1"

  if [ ! -d "$dir" ]; then
    echo "--share-dir must point to an existing directory: $dir" >&2
    exit 2
  fi

  dir="$(cd "$dir" && pwd -P)"
  case "$dir" in
  *":"*)
    echo "--share-dir must not contain colons (reserved by VM_HOST_SHARE_DIRS): $dir" >&2
    exit 2
    ;;
  *","*)
    echo "--share-dir must not contain commas (QEMU option separator): $dir" >&2
    exit 2
    ;;
  *[[:space:]]*)
    echo "--share-dir must not contain whitespace: $dir" >&2
    exit 2
    ;;
  esac

  printf '%s\n' "$dir"
}

if [ "$bootstrap_auth" -eq 1 ]; then
  auth_bootstrap_dir="$(@mktemp@ -d -t @vmName@-auth-bootstrap.XXXXXX)"
  managed_auth_bootstrap_dir=1
  if [ -f "$host_codex_auth_file" ]; then
    install -m 600 -- "$host_codex_auth_file" "$auth_bootstrap_dir/codex-auth.json"
  fi
  if [ -f "$host_claude_auth_file" ]; then
    install -m 600 -- "$host_claude_auth_file" "$auth_bootstrap_dir/claude-credentials.json"
  fi
  host_claude_settings="${CLAUDE_HOST_SETTINGS_FILE:-$HOME/.claude/settings.json}"
  if [ -f "$host_claude_settings" ]; then
    install -m 600 -- "$host_claude_settings" "$auth_bootstrap_dir/claude-settings.json"
  fi
fi
if [ "$bootstrap_auth" -eq 1 ] && [ -n "$auth_bootstrap_dir" ]; then
  export AUTH_VM_BOOTSTRAP_DIR="$auth_bootstrap_dir"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
  --keep-disk)
    cleanup_disk=0
    shift
    ;;
  --disk-image)
    disk_image="$2"
    shift 2
    ;;
  --share-dir)
    if [ "$use_cli_share_dirs" -eq 0 ]; then
      host_share_dirs=()
      use_cli_share_dirs=1
    fi
    host_share_dirs+=("$2")
    shift 2
    ;;
  --ram-mb)
    ram_mb="$2"
    override_ram=1
    shift 2
    ;;
  --cpus)
    cpus="$2"
    override_cpus=1
    shift 2
    ;;
  --disk-size)
    disk_size="$2"
    override_disk_size=1
    shift 2
    ;;
  --help | -h)
    cat <<'EOF'
Usage: nix run .#@vmName@-vm -- [OPTIONS] [-- RUNNER_ARGS...]

Options:
  --keep-disk        Keep disk image after VM exits
  --ram-mb MB        RAM in MiB (default: @defaultRamMb@)
  --cpus N           Number of CPUs (default: @defaultCpus@)
  --disk-size SIZE   Disk size (e.g. 8G, 16384M; default: @defaultDiskSize@)
  --disk-image PATH  Disk image path (default: @defaultDiskImage@)
  --share-dir PATH   Share host directory with the guest (repeatable)

Environment:
  NIX_DISK_IMAGE     Override disk image path (default: @defaultDiskImage@)
  VM_HOST_SHARE_DIR  Host directory shared to guest (single-share compatibility)
  VM_HOST_SHARE_DIRS Host directories shared to guest, colon-separated
  CODEX_HOST_AUTH_FILE   Host Codex auth file for one-way VM bootstrap (default: $HOME/.codex/auth.json)
  CLAUDE_HOST_AUTH_FILE  Host Claude auth file for one-way VM bootstrap (default: $HOME/.claude/.credentials)

Shared paths must not contain ':', commas, or whitespace.
EOF
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *)
    break
    ;;
  esac
done

if command -v ssh-keygen >/dev/null 2>&1; then
  # All VM apps currently forward guest SSH to host 127.0.0.1:2222.
  # Remove stale keys before boot to avoid host key mismatch warnings
  # when switching VM targets or recreating ephemeral VM disks.
  ssh-keygen -R "[127.0.0.1]:2222" >/dev/null 2>&1 || true
fi

export NIX_DISK_IMAGE="$disk_image"
if [ "${#host_share_dirs[@]}" -gt 0 ]; then
  declare -a validated_share_dirs=()
  for host_share_dir in "${host_share_dirs[@]}"; do
    [ -n "$host_share_dir" ] || continue
    host_share_dir="$(validate_share_dir "$host_share_dir")"
    validated_share_dirs+=("$host_share_dir")
  done
  host_share_dirs=("${validated_share_dirs[@]}")
fi

if [ "${#host_share_dirs[@]}" -gt 0 ]; then
  share_dirs_env=""
  for host_share_dir in "${host_share_dirs[@]}"; do
    share_dirs_env="${share_dirs_env:+$share_dirs_env:}$host_share_dir"
  done
  export VM_HOST_SHARE_DIRS="$share_dirs_env"

  if [ "${#host_share_dirs[@]}" -eq 1 ]; then
    export VM_HOST_SHARE_DIR="${host_share_dirs[0]}"
    export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-virtfs local,path=${host_share_dirs[0]},mount_tag=host-share,security_model=none,multidevs=remap"
  else
    unset VM_HOST_SHARE_DIR || true
    for host_share_dir in "${host_share_dirs[@]}"; do
      host_share_names+=("$(derive_share_name "$host_share_dir")")
    done
    for i in "${!host_share_dirs[@]}"; do
      export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-virtfs local,path=${host_share_dirs[i]},mount_tag=host-share-${host_share_names[i]},security_model=none,multidevs=remap"
    done
  fi
fi
if [ "$override_ram" -eq 1 ]; then
  export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-m $ram_mb"
fi
if [ "$override_cpus" -eq 1 ]; then
  export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-smp $cpus"
fi
if [ "$override_disk_size" -eq 1 ]; then
  if [ ! -e "$disk_image" ]; then
    tmp_raw="$(@mktemp@ -t @vmName@-disk.XXXXXX)"
    @qemuImg@ create -f raw "$tmp_raw" "$disk_size"
    @mkfsExt4@ -L nixos "$tmp_raw" >/dev/null
    @qemuImg@ convert -f raw -O qcow2 "$tmp_raw" "$disk_image"
    rm -f -- "$tmp_raw"
  else
    @qemuImg@ resize "$disk_image" "$disk_size" >/dev/null
  fi
fi

cleanup() {
  status="$?"
  if [ "$managed_auth_bootstrap_dir" -eq 1 ] && [ -n "$auth_bootstrap_dir" ]; then
    for f in "$auth_bootstrap_dir"/codex-auth.json "$auth_bootstrap_dir"/claude-credentials.json "$auth_bootstrap_dir"/claude-settings.json; do
      if [ -f "$f" ]; then
        shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
      fi
    done
    rm -rf -- "$auth_bootstrap_dir"
  fi
  if [ "$cleanup_disk" -eq 1 ] && [ -f "$disk_image" ]; then
    rm -f -- "$disk_image"
  fi
  exit "$status"
}

trap cleanup EXIT INT TERM

"@vmRunner@" "$@"
