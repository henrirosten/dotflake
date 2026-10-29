#!/usr/bin/env bash
set -euo pipefail

work=${1:-/work}
inbox=${2:-/mnt/agent-inbox}

if [[ -e $work || -L $work ]]; then
  echo "agent-init: target already exists: $work" >&2
  exit 1
fi
work=$(realpath -m -- "$work")
inbox=$(realpath -- "$inbox")
mkdir -p -- "$(dirname -- "$work")"
temporary=$(mktemp -d "$(dirname -- "$work")/.agent-init.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
heads=$(git bundle list-heads "$inbox/host.bundle")
branch=$(
  python3 - "$inbox/host.json" "$heads" <<'PY'
import json
import sys

tips = dict(line.split(" ", 1)[::-1] for line in sys.argv[2].split("\n") if line)
try:
    with open(sys.argv[1]) as source:
        manifest = json.load(source)
    branch = manifest.get("branch") if isinstance(manifest, dict) else None
    ref = f"refs/heads/{branch}"
    if isinstance(branch, str) and ref in tips and tips[ref] == manifest.get("commit"):
        print(branch)
        sys.exit(0)
except (OSError, ValueError):
    pass
print("agent-init: host.json must name a matching bundle branch and commit", file=sys.stderr)
sys.exit(1)
PY
)
git check-ref-format "refs/heads/$branch"
git clone --origin host --branch "$branch" "$inbox/host.bundle" "$temporary/repo"
mv -T -- "$temporary/repo" "$work"
