#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: dad-daemon-launcher.sh <log-file> <script> [args...]" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"

log_file="$1"
script="$2"
shift 2

dad_prepare_log_file "$log_file" || exit 2
exec >>"$log_file" 2>&1
chmod 600 "$log_file" 2>/dev/null || true
exec "$script" "$@"
