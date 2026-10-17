#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 "$PROJECT_ROOT/scripts/release.py" "$@"
