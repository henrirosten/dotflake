#!/usr/bin/env bash
set -euo pipefail

cleanup_disk=1
disk_image="${NIX_DISK_IMAGE:-@defaultDiskImage@}"
declare -a host_share_dirs=()
declare -a host_share_names=()
override_disk_size=0
tmp_raw=""

umask 077

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
    echo "--share-dir must not contain colons: $dir" >&2
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
    host_share_dirs+=("$2")
    shift 2
    ;;
  --ram-mb)
    export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-m $2"
    shift 2
    ;;
  --cpus)
    export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-smp $2"
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
  --share-dir PATH   Share host directory read-only (repeatable)

Environment:
  NIX_DISK_IMAGE     Override disk image path (default: @defaultDiskImage@)

Shared paths must not contain ':', commas, or whitespace.
EOF
    exit 0
    ;;
  --exec | --auth | --auth-replace | --project | --instance)
    echo "Unknown option: $1" >&2
    exit 2
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

cleanup() {
  status="$?"
  trap - EXIT INT TERM
  if [ "$cleanup_disk" -eq 1 ] && [ -f "$disk_image" ]; then
    rm -f -- "$disk_image"
  fi
  [ -z "$tmp_raw" ] || rm -f -- "$tmp_raw"
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    host_share_dir="$(validate_share_dir "$host_share_dir")" || exit 2
    validated_share_dirs+=("$host_share_dir")
  done
  host_share_dirs=("${validated_share_dirs[@]}")
fi

for host_share_dir in "${host_share_dirs[@]}"; do
  host_share_names+=("$(derive_share_name "$host_share_dir")")
done
for i in "${!host_share_dirs[@]}"; do
  tag=host-share
  if [ "${#host_share_dirs[@]}" -gt 1 ]; then
    tag="host-share-${host_share_names[i]}"
  fi
  export QEMU_OPTS="${QEMU_OPTS:+$QEMU_OPTS }-virtfs local,path=${host_share_dirs[i]},mount_tag=$tag,security_model=none,multidevs=remap,readonly=on"
done
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

"@vmRunner@" "$@"
