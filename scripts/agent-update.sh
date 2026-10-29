#!/usr/bin/env bash
set -euo pipefail

work=${1:-/work}
inbox=$(realpath -- "${2:-/mnt/agent-inbox}")

# Fetch from the bundle directly, independent of the guest's remote config.
git -C "$work" fetch --verbose "$inbox/host.bundle" '+refs/heads/*:refs/remotes/host/*'
