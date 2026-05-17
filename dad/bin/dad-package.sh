#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: dad-package.sh [--root <repo-root>] --output <artifact.tar.gz>

Create a clean DAD plugin archive from the repository tree, excluding runtime
state, git metadata, logs, locks, evidence, events, sockets, and bytecode.
USAGE
  exit 2
}

output=""
repo_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || usage
      repo_root="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$output" ]] || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$script_dir/../.." && pwd)"
fi
mkdir -p "$(dirname -- "$output")"

tar -C "$repo_root" \
  --exclude='./.git' \
  --exclude='./dad/events' \
  --exclude='dad/events' \
  --exclude='./dad/evidence' \
  --exclude='dad/evidence' \
  --exclude='./dad/history' \
  --exclude='dad/history' \
  --exclude='./dad/locks' \
  --exclude='dad/locks' \
  --exclude='./dad/logs' \
  --exclude='dad/logs' \
  --exclude='./dad/windows' \
  --exclude='dad/windows' \
  --exclude='__pycache__' \
  --exclude='*/__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.log' \
  --exclude='*.tmp' \
  --exclude='*.sock' \
  -czf "$output" \
  .claude-plugin .gitignore LICENSE README.md dad hooks skills

printf 'DAD_PACKAGE: %s\n' "$output"
