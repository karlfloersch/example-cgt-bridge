#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_ROOT_DEFAULT="$ROOT_DIR/devnet/work"
LIQUIDITY_CONTROLLER_PREDEPLOY="0x420000000000000000000000000000000000002a"
L2_MESSENGER_PREDEPLOY="0x4200000000000000000000000000000000000007"
IS_CUSTOM_GAS_TOKEN_PREDEPLOY="0x4200000000000000000000000000000000000015"
DEFAULT_DEV_FUNDED_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

log() {
  printf '\n[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required environment variable: $name"
}

require_address() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$name is not a valid address: $value"
}

json_address() {
  local file="$1"
  local jq_expr="$2"
  local value
  value="$(jq -r "$jq_expr // empty" "$file")"
  [[ -n "$value" ]] || die "Failed to parse address from $file with jq expression: $jq_expr"
  echo "$value"
}

run_op_deployer() {
  local mount_dir="$1"
  shift
  docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
    -v "$mount_dir:/work" -w /work \
    "$OP_DEPLOYER_IMAGE" \
    op-deployer "$@"
}

wait_for_l2_rpc() {
  local rpc="$1"
  local attempts=60
  local i
  for ((i = 1; i <= attempts; i++)); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
      return 0
    fi
    printf 'Waiting for L2 RPC (%s/%s)\n' "$i" "$attempts"
    sleep 2
  done
  return 1
}

extract_return_address() {
  local json_file="$1"
  local return_key="$2"
  local value
  value="$(jq -r ".returns.${return_key}.value // empty" "$json_file")"
  [[ -n "$value" ]] || die "Unable to read return value '${return_key}' from $json_file"
  echo "$value"
}

contract_has_code() {
  local rpc_url="$1"
  local address="$2"
  local code
  code="$(cast code "$address" --rpc-url "$rpc_url" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" ]]
}

wait_for_contract_code() {
  local rpc_url="$1"
  local address="$2"
  local attempts="$3"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if contract_has_code "$rpc_url" "$address"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

run_forge_create_with_retry() {
  local description="$1"
  local rpc_url="$2"
  local json_file="$3"
  local return_key="$4"
  shift 4
  local -a cmd=("$@")
  local attempt rc deployed_address parse_file candidate
  local json_dir
  json_dir="$(dirname "$json_file")"
  mkdir -p "$json_dir"

  for ((attempt = 1; attempt <= FORGE_BROADCAST_MAX_ATTEMPTS; attempt++)); do
    # Avoid reading stale addresses from a previous forge run.
    rm -f "$json_file" "$json_dir"/run-*.json
    if "$TIMEOUT_BIN" "${FORGE_BROADCAST_TIMEOUT_SECONDS}s" "${cmd[@]}" >/dev/null; then
      rc=0
    else
      rc=$?
      if [[ "$rc" == "124" ]]; then
        log "$description attempt $attempt/$FORGE_BROADCAST_MAX_ATTEMPTS timed out while waiting for receipts"
      else
        log "$description attempt $attempt/$FORGE_BROADCAST_MAX_ATTEMPTS failed with exit code $rc"
      fi
    fi

    deployed_address=""
    parse_file=""
    if [[ -f "$json_file" ]]; then
      parse_file="$json_file"
    else
      for candidate in "$json_dir"/run-*.json; do
        [[ -f "$candidate" ]] || continue
        parse_file="$candidate"
      done
    fi

    if [[ -n "$parse_file" && -f "$parse_file" ]]; then
      deployed_address="$(jq -r ".returns.${return_key}.value // empty" "$parse_file")"
      if [[ "$parse_file" != "$json_file" ]]; then
        cp "$parse_file" "$json_file"
      fi
    fi

    if [[ "$deployed_address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      if wait_for_contract_code "$rpc_url" "$deployed_address" "$FORGE_CONTRACT_WAIT_ATTEMPTS"; then
        log "$description confirmed at $deployed_address"
        return 0
      fi
      log "$description returned $deployed_address but code was not found yet"
    fi

    if (( attempt < FORGE_BROADCAST_MAX_ATTEMPTS )); then
      log "Retrying $description in ${FORGE_RETRY_SLEEP_SECONDS}s"
      sleep "$FORGE_RETRY_SLEEP_SECONDS"
    fi
  done

  die "$description failed after $FORGE_BROADCAST_MAX_ATTEMPTS attempts"
}

run_forge_call_with_retry() {
  local description="$1"
  local verify_cmd="$2"
  shift 2
  local -a cmd=("$@")
  local attempt rc

  for ((attempt = 1; attempt <= FORGE_BROADCAST_MAX_ATTEMPTS; attempt++)); do
    if "$TIMEOUT_BIN" "${FORGE_BROADCAST_TIMEOUT_SECONDS}s" "${cmd[@]}" >/dev/null; then
      rc=0
    else
      rc=$?
      if [[ "$rc" == "124" ]]; then
        log "$description attempt $attempt/$FORGE_BROADCAST_MAX_ATTEMPTS timed out while waiting for receipts"
      else
        log "$description attempt $attempt/$FORGE_BROADCAST_MAX_ATTEMPTS failed with exit code $rc"
      fi
    fi

    if eval "$verify_cmd"; then
      return 0
    fi

    if (( attempt < FORGE_BROADCAST_MAX_ATTEMPTS )); then
      log "Retrying $description in ${FORGE_RETRY_SLEEP_SECONDS}s"
      sleep "$FORGE_RETRY_SLEEP_SECONDS"
    fi
  done

  die "$description failed after $FORGE_BROADCAST_MAX_ATTEMPTS attempts"
}

ensure_l2_gas_for_deployer() {
  local l2_rpc_url="$1"
  local required_wei="$2"

  local deployer_balance
  deployer_balance="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$l2_rpc_url")"
  if (( deployer_balance >= required_wei )); then
    log "Deployer has sufficient L2 gas balance: $deployer_balance wei"
    return 0
  fi

  if [[ "${L2_AUTO_FUND_DEPLOYER:-true}" != "true" ]]; then
    die "Deployer L2 balance is too low ($deployer_balance wei). Set L2_AUTO_FUND_DEPLOYER=true or pre-fund $DEPLOYER_ADDRESS"
  fi

  local faucet_key="${L2_FAUCET_KEY:-$DEFAULT_DEV_FUNDED_KEY}"
  local faucet_address faucet_balance
  faucet_address="$(cast wallet address --private-key "$faucet_key")"
  faucet_balance="$(cast balance "$faucet_address" --rpc-url "$l2_rpc_url")"
  if (( faucet_balance < required_wei )); then
    die "Faucet key has insufficient L2 balance ($faucet_balance wei). Set L2_FAUCET_KEY to a funded key."
  fi

  local fund_wei="${L2_DEPLOYER_FUND_WEI:-1000000000000000000}"
  [[ "$fund_wei" =~ ^[0-9]+$ ]] || die "L2_DEPLOYER_FUND_WEI must be an integer"
  if (( fund_wei < required_wei )); then
    fund_wei="$required_wei"
  fi

  log "Auto-funding deployer on L2 from faucet account"
  cast send "$DEPLOYER_ADDRESS" \
    --value "$fund_wei" \
    --private-key "$faucet_key" \
    --rpc-url "$l2_rpc_url" >/dev/null

  deployer_balance="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$l2_rpc_url")"
  if (( deployer_balance < required_wei )); then
    die "Deployer L2 balance still insufficient after funding: $deployer_balance wei"
  fi
  log "Deployer funded on L2: $deployer_balance wei"
}

require_cmd docker
require_cmd jq
require_cmd cast
require_cmd forge
require_cmd openssl
require_cmd npm
require_cmd rg
docker compose version >/dev/null 2>&1 || die "Missing docker compose plugin"

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  die "Missing required command: timeout (or gtimeout on macOS)"
fi

require_env L1_RPC
require_env L1_BEACON
require_env DEPLOYER_KEY
require_env SEQUENCER_KEY
require_env BATCHER_KEY
require_env PROPOSER_KEY

OP_DEPLOYER_IMAGE="${OP_DEPLOYER_IMAGE:-us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2}"
OP_RETH_IMAGE="${OP_RETH_IMAGE:-us-docker.pkg.dev/oplabs-tools-artifacts/images/op-reth:v1.10.0}"
WORK_ROOT="${WORK_ROOT:-$WORK_ROOT_DEFAULT}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
L2_HTTP_PORT="${L2_HTTP_PORT:-19545}"
L2_WS_PORT="${L2_WS_PORT:-19546}"
L2_AUTH_PORT="${L2_AUTH_PORT:-19551}"
OP_NODE_RPC_PORT="${OP_NODE_RPC_PORT:-17000}"
FORGE_BROADCAST_TIMEOUT_SECONDS="${FORGE_BROADCAST_TIMEOUT_SECONDS:-180}"
FORGE_BROADCAST_MAX_ATTEMPTS="${FORGE_BROADCAST_MAX_ATTEMPTS:-3}"
FORGE_RETRY_SLEEP_SECONDS="${FORGE_RETRY_SLEEP_SECONDS:-8}"
FORGE_CONTRACT_WAIT_ATTEMPTS="${FORGE_CONTRACT_WAIT_ATTEMPTS:-20}"
[[ "$FORGE_BROADCAST_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "FORGE_BROADCAST_TIMEOUT_SECONDS must be an integer"
[[ "$FORGE_BROADCAST_MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || die "FORGE_BROADCAST_MAX_ATTEMPTS must be an integer"
[[ "$FORGE_RETRY_SLEEP_SECONDS" =~ ^[0-9]+$ ]] || die "FORGE_RETRY_SLEEP_SECONDS must be an integer"
[[ "$FORGE_CONTRACT_WAIT_ATTEMPTS" =~ ^[0-9]+$ ]] || die "FORGE_CONTRACT_WAIT_ATTEMPTS must be an integer"

TOKEN_NAME="${TOKEN_NAME:-Devnet USD}"
TOKEN_SYMBOL="${TOKEN_SYMBOL:-dUSD}"
TOKEN_DECIMALS="${TOKEN_DECIMALS:-6}"
TOKEN_INITIAL_SUPPLY_TOKENS="${TOKEN_INITIAL_SUPPLY_TOKENS:-10000000}"
[[ "$TOKEN_DECIMALS" =~ ^[0-9]+$ ]] || die "TOKEN_DECIMALS must be an integer"
[[ "$TOKEN_INITIAL_SUPPLY_TOKENS" =~ ^[0-9]+$ ]] || die "TOKEN_INITIAL_SUPPLY_TOKENS must be an integer"
TOKEN_INITIAL_SUPPLY_RAW="${TOKEN_INITIAL_SUPPLY_TOKENS}$(printf '%0*d' "$TOKEN_DECIMALS" 0)"

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_KEY")"
DEPLOYER_KEY_HEX="0x${DEPLOYER_KEY#0x}"
SEQUENCER_ADDRESS="$(cast wallet address --private-key "$SEQUENCER_KEY")"
BATCHER_ADDRESS="$(cast wallet address --private-key "$BATCHER_KEY")"
PROPOSER_ADDRESS="$(cast wallet address --private-key "$PROPOSER_KEY")"

SUPERCHAIN_PROXY_ADMIN_OWNER="${SUPERCHAIN_PROXY_ADMIN_OWNER:-$DEPLOYER_ADDRESS}"
PROTOCOL_VERSIONS_OWNER="${PROTOCOL_VERSIONS_OWNER:-$DEPLOYER_ADDRESS}"
GUARDIAN_ADDRESS="${GUARDIAN_ADDRESS:-$DEPLOYER_ADDRESS}"
L1_PROXY_ADMIN_OWNER="${L1_PROXY_ADMIN_OWNER:-$DEPLOYER_ADDRESS}"
CHALLENGER_ADDRESS="${CHALLENGER_ADDRESS:-$DEPLOYER_ADDRESS}"

require_address "DEPLOYER_ADDRESS" "$DEPLOYER_ADDRESS"
require_address "SEQUENCER_ADDRESS" "$SEQUENCER_ADDRESS"
require_address "BATCHER_ADDRESS" "$BATCHER_ADDRESS"
require_address "PROPOSER_ADDRESS" "$PROPOSER_ADDRESS"
require_address "SUPERCHAIN_PROXY_ADMIN_OWNER" "$SUPERCHAIN_PROXY_ADMIN_OWNER"
require_address "PROTOCOL_VERSIONS_OWNER" "$PROTOCOL_VERSIONS_OWNER"
require_address "GUARDIAN_ADDRESS" "$GUARDIAN_ADDRESS"
require_address "L1_PROXY_ADMIN_OWNER" "$L1_PROXY_ADMIN_OWNER"
require_address "CHALLENGER_ADDRESS" "$CHALLENGER_ADDRESS"

if [[ -z "${L2_CHAIN_ID_DEC:-}" ]]; then
  L2_CHAIN_ID_DEC="$((300000000000000 + $(date -u +%s) + RANDOM))"
fi
L2_CHAIN_ID_HEX="$(printf '0x%064x\n' "$L2_CHAIN_ID_DEC")"

SUPERCHAIN_DIR="$WORK_ROOT/superchain-$RUN_ID"
IMPL_DIR="$WORK_ROOT/implementations-$RUN_ID"
CHAIN_DIR="$WORK_ROOT/netnew-$RUN_ID"
mkdir -p "$SUPERCHAIN_DIR" "$IMPL_DIR" "$CHAIN_DIR"

cd "$ROOT_DIR"

log "Stopping existing docker compose services"
docker compose -f "$ROOT_DIR/devnet/docker-compose.yml" -p cgt-devnet down --remove-orphans -v || true

log "Bootstrapping new superchain singletons"
run_op_deployer "$SUPERCHAIN_DIR" bootstrap superchain \
  --l1-rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY" \
  --superchain-proxy-admin-owner "$SUPERCHAIN_PROXY_ADMIN_OWNER" \
  --protocol-versions-owner "$PROTOCOL_VERSIONS_OWNER" \
  --guardian "$GUARDIAN_ADDRESS" \
  --outfile /work/bootstrap-superchain.json

SUPERCHAIN_CONFIG_PROXY="$(json_address "$SUPERCHAIN_DIR/bootstrap-superchain.json" '.superchainConfigProxyAddress // .superchainConfigProxy // .SuperchainConfigProxy')"
PROTOCOL_VERSIONS_PROXY="$(json_address "$SUPERCHAIN_DIR/bootstrap-superchain.json" '.protocolVersionsProxyAddress // .protocolVersionsProxy // .ProtocolVersionsProxy')"
SUPERCHAIN_PROXY_ADMIN="$(json_address "$SUPERCHAIN_DIR/bootstrap-superchain.json" '.proxyAdminAddress // .ProxyAdmin // .superchainProxyAdmin')"

require_address "SUPERCHAIN_CONFIG_PROXY" "$SUPERCHAIN_CONFIG_PROXY"
require_address "PROTOCOL_VERSIONS_PROXY" "$PROTOCOL_VERSIONS_PROXY"
require_address "SUPERCHAIN_PROXY_ADMIN" "$SUPERCHAIN_PROXY_ADMIN"

log "Bootstrapping fast implementations and OPCM"
run_op_deployer "$IMPL_DIR" bootstrap implementations \
  --l1-rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY" \
  --superchain-config-proxy "$SUPERCHAIN_CONFIG_PROXY" \
  --protocol-versions-proxy "$PROTOCOL_VERSIONS_PROXY" \
  --superchain-proxy-admin "$SUPERCHAIN_PROXY_ADMIN" \
  --l1-proxy-admin-owner "$L1_PROXY_ADMIN_OWNER" \
  --challenger "$CHALLENGER_ADDRESS" \
  --challenge-period-seconds 5 \
  --proof-maturity-delay-seconds 15 \
  --dispute-game-finality-delay-seconds 1 \
  --dispute-clock-extension 5 \
  --dispute-max-clock-duration 15 \
  --outfile /work/bootstrap-implementations.json

OPCM_ADDRESS="$(json_address "$IMPL_DIR/bootstrap-implementations.json" '.opcmAddress')"
require_address "OPCM_ADDRESS" "$OPCM_ADDRESS"

log "Initializing custom intent for net-new chain"
run_op_deployer "$CHAIN_DIR" init \
  --workdir /work \
  --intent-type custom \
  --l1-chain-id 11155111 \
  --l2-chain-ids "$L2_CHAIN_ID_DEC"

cp "$ROOT_DIR/devnet/intent.toml.example" "$CHAIN_DIR/intent.toml"

sed -i "s|0xYOUR_BOOTSTRAPPED_OPCM_ADDRESS|$OPCM_ADDRESS|g" "$CHAIN_DIR/intent.toml"
sed -i "s|0x00000000000000000000000000000000000000000000000000000000deadbeef|$L2_CHAIN_ID_HEX|g" "$CHAIN_DIR/intent.toml"
sed -i "s|0xYOUR_ADDRESS|$DEPLOYER_ADDRESS|g" "$CHAIN_DIR/intent.toml"
sed -i "s|0xYOUR_SEQUENCER_ADDRESS|$SEQUENCER_ADDRESS|g" "$CHAIN_DIR/intent.toml"
sed -i "s|0xYOUR_BATCHER_ADDRESS|$BATCHER_ADDRESS|g" "$CHAIN_DIR/intent.toml"
sed -i "s|0xYOUR_PROPOSER_ADDRESS|$PROPOSER_ADDRESS|g" "$CHAIN_DIR/intent.toml"

log "Applying intent (deploying L1 contracts)"
run_op_deployer "$CHAIN_DIR" apply \
  --workdir /work \
  --l1-rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY"

CHAIN_ID_HEX="$(jq -r '.appliedIntent.chains[0].id' "$CHAIN_DIR/state.json")"
CHAIN_ID_DEC="$(cast to-dec "$CHAIN_ID_HEX")"
DISPUTE_GAME_FACTORY="$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' "$CHAIN_DIR/state.json")"
PORTAL_PROXY="$(jq -r '.opChainDeployments[0].OptimismPortalProxy' "$CHAIN_DIR/state.json")"
L1_MESSENGER="$(jq -r '.opChainDeployments[0].L1CrossDomainMessengerProxy' "$CHAIN_DIR/state.json")"

log "Generating deploy-config/genesis/rollup artifacts"
run_op_deployer "$CHAIN_DIR" inspect deploy-config \
  --workdir /work \
  --outfile /work/deploy-config.json \
  "$CHAIN_ID_DEC"

run_op_deployer "$CHAIN_DIR" inspect genesis \
  --workdir /work \
  --outfile /work/genesis.json \
  "$CHAIN_ID_DEC"

run_op_deployer "$CHAIN_DIR" inspect rollup \
  --workdir /work \
  --outfile /work/rollup.json \
  "$CHAIN_ID_DEC"

USE_CGT="$(jq -r '.useCustomGasToken' "$CHAIN_DIR/deploy-config.json")"
[[ "$USE_CGT" == "true" ]] || die "Deploy config useCustomGasToken is not true: $USE_CGT"

BATCH_INBOX="$(jq -r '.batch_inbox_address' "$CHAIN_DIR/rollup.json")"

cp "$CHAIN_DIR/genesis.json" "$ROOT_DIR/devnet/genesis.json"
cp "$CHAIN_DIR/rollup.json" "$ROOT_DIR/devnet/rollup.json"
openssl rand -hex 32 > "$ROOT_DIR/devnet/jwt.hex"
openssl rand -hex 32 > "$ROOT_DIR/devnet/p2p-key.txt"

log "Writing devnet/.env"
cat > "$ROOT_DIR/devnet/.env" <<EOF
L1_RPC=$L1_RPC
L1_BEACON=$L1_BEACON
SEQUENCER_KEY=$SEQUENCER_KEY
BATCHER_KEY=$BATCHER_KEY
PROPOSER_KEY=$PROPOSER_KEY
L2_CHAIN_ID=$CHAIN_ID_DEC
DISPUTE_GAME_FACTORY=$DISPUTE_GAME_FACTORY
BATCH_INBOX=$BATCH_INBOX
OP_RETH_IMAGE=$OP_RETH_IMAGE
GENESIS_FILE=./genesis.json
ROLLUP_FILE=./rollup.json
JWT_FILE=./jwt.hex
P2P_KEY_FILE=./p2p-key.txt
L2_HTTP_PORT=$L2_HTTP_PORT
L2_WS_PORT=$L2_WS_PORT
L2_AUTH_PORT=$L2_AUTH_PORT
OP_NODE_RPC_PORT=$OP_NODE_RPC_PORT
EOF

log "Starting docker compose services"
(cd "$ROOT_DIR/devnet" && docker compose up -d)
(cd "$ROOT_DIR/devnet" && docker compose ps)

L2_RPC_URL="http://127.0.0.1:${L2_HTTP_PORT}"
if ! wait_for_l2_rpc "$L2_RPC_URL"; then
  die "L2 RPC did not come up on $L2_RPC_URL"
fi

L2_CHAIN_CHECK="$(cast chain-id --rpc-url "$L2_RPC_URL")"
[[ "$L2_CHAIN_CHECK" == "$CHAIN_ID_DEC" ]] || die "Unexpected L2 chain id. expected=$CHAIN_ID_DEC got=$L2_CHAIN_CHECK"

IS_CGT="$(cast call "$IS_CUSTOM_GAS_TOKEN_PREDEPLOY" 'isCustomGasToken()(bool)' --rpc-url "$L2_RPC_URL")"
[[ "$IS_CGT" == "true" ]] || die "isCustomGasToken returned $IS_CGT"

ensure_l2_gas_for_deployer "$L2_RPC_URL" "${L2_DEPLOYER_MIN_WEI:-200000000000000000}"

log "Validating fast override values for permissioned dispute game"
PERMISSIONED_IMPL="$(cast call "$DISPUTE_GAME_FACTORY" 'gameImpls(uint32)(address)' 1 --rpc-url "$L1_RPC")"
MAX_CLOCK="$(cast call "$PERMISSIONED_IMPL" 'maxClockDuration()(uint64)' --rpc-url "$L1_RPC")"
CLOCK_EXT="$(cast call "$PERMISSIONED_IMPL" 'clockExtension()(uint64)' --rpc-url "$L1_RPC")"
PROOF_DELAY="$(cast call "$PORTAL_PROXY" 'proofMaturityDelaySeconds()(uint256)' --rpc-url "$L1_RPC")"
FINALITY_DELAY="$(cast call "$PORTAL_PROXY" 'disputeGameFinalityDelaySeconds()(uint256)' --rpc-url "$L1_RPC")"

[[ "$MAX_CLOCK" == "15" ]] || die "Unexpected maxClockDuration: $MAX_CLOCK"
[[ "$CLOCK_EXT" == "5" ]] || die "Unexpected clockExtension: $CLOCK_EXT"
[[ "$PROOF_DELAY" == "15" ]] || die "Unexpected proofMaturityDelaySeconds: $PROOF_DELAY"
[[ "$FINALITY_DELAY" == "1" ]] || die "Unexpected disputeGameFinalityDelaySeconds: $FINALITY_DELAY"

log "Deploying devnet ERC-20 token on L1"
L1_TOKEN_BROADCAST_JSON="$ROOT_DIR/broadcast/DeployDevnetMintableToken.s.sol/11155111/run-latest.json"
run_forge_create_with_retry "L1 token deployment" "$L1_RPC" "$L1_TOKEN_BROADCAST_JSON" "token_" \
  forge script script/DeployDevnetMintableToken.s.sol:DeployDevnetMintableToken \
  --sig "run(string,string,uint8,address,uint256)" \
  "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS" "$DEPLOYER_ADDRESS" "$TOKEN_INITIAL_SUPPLY_RAW" \
  --rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY" \
  --broadcast

L1_TOKEN="$(extract_return_address "$L1_TOKEN_BROADCAST_JSON" "token_")"
require_address "L1_TOKEN" "$L1_TOKEN"

log "Deploying bridge contracts (L1 then L2)"
L2_NONCE="$(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$L2_RPC_URL")"
L2_BRIDGE_PREDICTED="$(cast compute-address "$DEPLOYER_ADDRESS" --nonce "$L2_NONCE" | rg -o '0x[a-fA-F0-9]{40}' | tail -n1)"
require_address "L2_BRIDGE_PREDICTED" "$L2_BRIDGE_PREDICTED"

L1_BRIDGE_BROADCAST_JSON="$ROOT_DIR/broadcast/DeployCGTBridge.s.sol/11155111/run-latest.json"
run_forge_create_with_retry "L1 bridge deployment" "$L1_RPC" "$L1_BRIDGE_BROADCAST_JSON" "bridge_" \
  forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL1 \
  --sig "run(address,uint8,address,address)" \
  "$L1_TOKEN" "$TOKEN_DECIMALS" "$L2_BRIDGE_PREDICTED" "$L1_MESSENGER" \
  --rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY" \
  --broadcast

L1_BRIDGE="$(extract_return_address "$L1_BRIDGE_BROADCAST_JSON" "bridge_")"
require_address "L1_BRIDGE" "$L1_BRIDGE"

L2_BRIDGE_BROADCAST_JSON="$ROOT_DIR/broadcast/DeployCGTBridge.s.sol/$CHAIN_ID_DEC/run-latest.json"
run_forge_create_with_retry "L2 bridge deployment" "$L2_RPC_URL" "$L2_BRIDGE_BROADCAST_JSON" "bridge_" \
  forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL2 \
  --sig "run(address,address,uint8,address)" \
  "$L1_BRIDGE" "$L2_MESSENGER_PREDEPLOY" "$TOKEN_DECIMALS" "$LIQUIDITY_CONTROLLER_PREDEPLOY" \
  --rpc-url "$L2_RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  --broadcast

L2_BRIDGE="$(extract_return_address "$L2_BRIDGE_BROADCAST_JSON" "bridge_")"
require_address "L2_BRIDGE" "$L2_BRIDGE"

[[ "${L2_BRIDGE,,}" == "${L2_BRIDGE_PREDICTED,,}" ]] || die "L2 bridge address mismatch. predicted=$L2_BRIDGE_PREDICTED actual=$L2_BRIDGE"

log "Authorizing L2 bridge as LiquidityController minter"
run_forge_call_with_retry "L2 bridge minter authorization" \
  '[[ "$(cast call "$LIQUIDITY_CONTROLLER_PREDEPLOY" '"'"'minters(address)(bool)'"'"' "$L2_BRIDGE" --rpc-url "$L2_RPC_URL")" == "true" ]]' \
  forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL2 \
  --sig "authorizeMinter(address,address)" \
  "$LIQUIDITY_CONTROLLER_PREDEPLOY" "$L2_BRIDGE" \
  --rpc-url "$L2_RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  --broadcast

IS_MINTER="$(cast call "$LIQUIDITY_CONTROLLER_PREDEPLOY" 'minters(address)(bool)' "$L2_BRIDGE" --rpc-url "$L2_RPC_URL")"
[[ "$IS_MINTER" == "true" ]] || die "L2 bridge was not authorized as minter"

log "Writing scripts/.env.runtime and devnet/work/e2e-latest.env"
cat > "$ROOT_DIR/scripts/.env.runtime" <<EOF
L1_RPC=$L1_RPC
L2_RPC=$L2_RPC_URL
PRIVATE_KEY=$DEPLOYER_KEY_HEX
L2_CHAIN_ID=$CHAIN_ID_DEC
L1_BRIDGE=$L1_BRIDGE
L2_BRIDGE=$L2_BRIDGE
L1_TOKEN=$L1_TOKEN
TOKEN_DECIMALS=$TOKEN_DECIMALS
DISPUTE_GAME_FACTORY=$DISPUTE_GAME_FACTORY
PORTAL_ADDRESS=$PORTAL_PROXY
EOF

cat > "$ROOT_DIR/devnet/work/e2e-latest.env" <<EOF
RUN_ID=$RUN_ID
WORKDIR=$CHAIN_DIR
SUPERCHAIN_DIR=$SUPERCHAIN_DIR
IMPLEMENTATIONS_DIR=$IMPL_DIR
L2_CHAIN_ID=$CHAIN_ID_DEC
L1_BRIDGE=$L1_BRIDGE
L2_BRIDGE=$L2_BRIDGE
L1_TOKEN=$L1_TOKEN
TOKEN_DECIMALS=$TOKEN_DECIMALS
DISPUTE_GAME_FACTORY=$DISPUTE_GAME_FACTORY
PORTAL_ADDRESS=$PORTAL_PROXY
L2_RPC=$L2_RPC_URL
EOF

log "Deployment complete"
echo "Run deposit test:   just deposit-test 1"
echo "Run withdrawal test: just withdraw-test 1"
