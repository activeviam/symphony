#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version|version|help)
    exec /usr/bin/gh "$@"
    ;;
esac

export GH_HOST="${GH_HOST:-github.com}"
GH_TOKEN="$(/usr/local/bin/github-app-token)"
export GH_TOKEN
exec /usr/bin/gh "$@"
