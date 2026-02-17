#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_PHASE=bridge "$ROOT_DIR/devnet/scripts/deploy-new-superchain-and-chain.sh"
