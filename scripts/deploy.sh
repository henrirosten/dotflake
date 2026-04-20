#!/usr/bin/env bash

set -euo pipefail

SUBNET="192.168.1.0/24"
SSH_USER="${USER:-$(id -un)}"

declare -A HOST_MACS=(
  [nocturn]="f0:2f:74:15:d9:a9"
  [t14s]="8c:f8:c5:33:09:64"
)

log() {
  printf "[deploy] %s\n" "$*" >&2
}

resolve_ip() {
  local mac="$1"
  ip neigh | awk -v mac="$mac" 'tolower($0) ~ tolower(mac) {print $1; exit}'
}

run_nmap() {
  if command -v nmap >/dev/null 2>&1; then
    log "Using nmap from PATH"
    nmap "$@"
  else
    log "Using nix shell fallback for nmap"
    nix shell nixpkgs#nmap --command nmap "$@"
  fi
}

resolve_all() {
  local scanned=false
  for h in "${!HOST_MACS[@]}"; do
    local addr
    log "Checking ARP cache for $h (${HOST_MACS[$h]})"
    addr=$(resolve_ip "${HOST_MACS[$h]}")
    if [[ -z $addr ]] && [[ $scanned == false ]]; then
      log "Host missing from ARP cache, scanning $SUBNET"
      run_nmap -sn "$SUBNET" >/dev/null 2>&1
      scanned=true
      addr=$(resolve_ip "${HOST_MACS[$h]}")
    fi
    if [[ -n $addr ]]; then
      printf "  %-12s %s (ssh %s@%s)\n" "$h" "$addr" "$SSH_USER" "$addr"
    else
      printf "  %-12s not found on %s\n" "$h" "$SUBNET"
    fi
  done
}

usage() {
  echo "Deploy a NixOS configuration to a remote host."
  echo ""
  echo "Usage: $0 [options] <host> [action] [nixos-rebuild args...]"
  echo "       $0 [options] --list"
  echo ""
  echo "Actions: switch (default), dry-activate, test, boot"
  echo ""
  echo "Options:"
  echo "  --user USER      SSH user (default: current user)"
  echo "  --subnet CIDR    Subnet to scan (default: $SUBNET)"
  echo "  --list           Resolve and display host IPs"
  echo ""
  echo "Available hosts:"
  for h in "${!HOST_MACS[@]}"; do
    echo "  $h  (${HOST_MACS[$h]})"
  done
  echo ""
  echo "Examples:"
  echo "  $0 nocturn"
  echo "  $0 nocturn dry-activate"
  echo "  $0 --user admin --subnet 10.0.0.0/24 nocturn"
  echo "  $0 --list"
  exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --user)
    [[ $# -ge 2 ]] || {
      echo "Error: --user requires a value" >&2
      usage
    }
    SSH_USER="$2"
    shift 2
    ;;
  --subnet)
    [[ $# -ge 2 ]] || {
      echo "Error: --subnet requires a value" >&2
      usage
    }
    SUBNET="$2"
    shift 2
    ;;
  *)
    break
    ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
fi

if [[ $1 == "-h" ]] || [[ $1 == "--help" ]]; then
  usage 0
fi

if [[ $1 == "--list" ]]; then
  echo "Resolving hosts on $SUBNET ..."
  resolve_all
  exit 0
fi

host="$1"
shift

if [[ -z ${HOST_MACS[$host]+x} ]]; then
  echo "Error: unknown host '$host'" >&2
  usage
fi

action="switch"
if [[ $# -gt 0 ]]; then
  case "$1" in
  switch | dry-activate | test | boot)
    action="$1"
    shift
    ;;
  esac
fi

mac="${HOST_MACS[$host]}"
log "Preparing deployment"
log "Host: $host"
log "Action: $action"
log "SSH user: $SSH_USER"
log "Subnet: $SUBNET"
log "MAC: $mac"
if [[ $# -gt 0 ]]; then
  log "Extra nixos-rebuild args: $*"
fi

log "Checking ARP cache for $host"
addr=$(resolve_ip "$mac")

if [[ -z $addr ]]; then
  log "Host not in ARP cache, scanning $SUBNET"
  run_nmap -sn "$SUBNET" >/dev/null 2>&1
  addr=$(resolve_ip "$mac")
fi

if [[ -z $addr ]]; then
  echo "Error: could not find host '$host' (MAC $mac) on $SUBNET" >&2
  exit 1
fi

log "Resolved $host to $addr"
log "Deploying .#$host to $SSH_USER@$addr ($mac)"
log "Running: nixos-rebuild $action --flake .#$host --target-host $SSH_USER@$addr --sudo${*:+ $*}"
nixos-rebuild "$action" \
  --flake ".#$host" \
  --target-host "$SSH_USER@$addr" \
  --sudo \
  "$@"
