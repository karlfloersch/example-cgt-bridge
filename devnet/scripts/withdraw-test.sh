#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMOUNT="${1:-1}"
RESUME_HASH="${2:-}"

[[ -f "$ROOT_DIR/tasks/.env.runtime" ]] || {
  echo "Missing $ROOT_DIR/tasks/.env.runtime. Run 'just deploy-chain' then 'just deploy-bridge' first." >&2
  exit 1
}

if [[ ! -d "$ROOT_DIR/tasks/node_modules" ]]; then
  echo "Installing Node dependencies in tasks/..."
  if [[ -f "$ROOT_DIR/tasks/package-lock.json" ]]; then
    (cd "$ROOT_DIR/tasks" && npm ci --no-audit --no-fund)
  else
    (cd "$ROOT_DIR/tasks" && npm install --no-audit --no-fund)
  fi
fi

set -a
source "$ROOT_DIR/tasks/.env.runtime"
set +a

cd "$ROOT_DIR/tasks"
if [[ -n "$RESUME_HASH" ]]; then
  npx tsx withdraw.ts "$AMOUNT" --resume-hash "$RESUME_HASH"
else
  npx tsx withdraw.ts "$AMOUNT"
fi
