#!/usr/bin/env bash
set -euo pipefail

work=${1:-/work}
outbox=${2:-/mnt/agent-outbox}

outbox=$(realpath -- "$outbox")
cd -- "$work"
exec 9>"$(git rev-parse --git-path agent-export.lock)"
flock 9
if ! head=$(git rev-parse --verify 'HEAD^{commit}'); then
  echo "agent-export: unborn HEAD; commit before exporting" >&2
  exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"; rm -f -- "$outbox/.export.tmp"' EXIT
export GIT_INDEX_FILE="$temporary/index"
git read-tree "$head"
git add -A
tree=$(git write-tree)
if [[ $tree == "$(git rev-parse "$head^{tree}")" ]]; then
  wip=$head
else
  wip=$(git -c user.name='Dotflake agent' -c user.email=agent@dotflake.invalid \
    commit-tree "$tree" -p "$head" -m 'Snapshot agent work in progress')
fi
git update-ref refs/export/wip "$wip"
git bundle create --version=2 "$outbox/.export.tmp" --branches refs/export/wip
mv -f -- "$outbox/.export.tmp" "$outbox/export.bundle"
echo "Exported WIP $wip to $outbox/export.bundle"
