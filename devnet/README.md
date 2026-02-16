# CGT Devnet (Net-New + Docker Compose)

This guide deploys a brand-new CGT OP Stack network on Sepolia, starts services with Docker Compose, and validates fast dispute-game overrides.

All paths are repo-relative (`$PWD/devnet/...`) so this is portable across machines.

## Quickstart (Recommended)

Use the automated flow with three commands:

```bash
mise install
cp devnet/.env.deploy.example .env
# edit .env with your Sepolia RPC + funded keys
source .env

just deploy
just deposit-test 1
just withdraw-test 1
# if a withdrawal run is interrupted, resume from existing L2 withdrawal tx:
# just withdraw-test 1 0x<withdraw_tx_hash>
```

What `just deploy` does:

- Stops existing local services
- Bootstraps a brand-new superchain (`bootstrap superchain`)
- Bootstraps implementations + OPCM (`bootstrap implementations`)
- Deploys a net-new custom intent chain (`init` + `apply`)
- Starts Docker Compose services
- Validates CGT mode and permissioned dispute-game fast overrides
- Auto-funds the deployer on L2 (when needed) from a funded dev account
- Deploys a test ERC-20 + bridge pair
- Writes `scripts/.env.runtime` for the deposit/withdraw test commands

## Versions + Critical Notes

- `op-deployer` must be pinned to `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2` for this CGT flow.
- Use `intent-type custom` / `configType = "custom"`.
- `bootstrap implementations` requires:
  - `--superchain-config-proxy`
  - `--protocol-versions-proxy`
  - `--superchain-proxy-admin`
  - `--challenger`
- If `opcmAddress` is set in custom intent, do **not** include `[superchainRoles]`.
- `op-batcher` must disable throttling for this reth setup (`--throttle.unsafe-da-bytes-lower-threshold=0`).
- `op-reth` needs a large proof window for withdrawal proving (`--rpc.eth-proof-window=1000000`).
- Even with fast dispute-game overrides, withdrawal proving/finalization can take a few minutes depending on proposer/batcher progress and Sepolia timing.
- `just deploy` creates a new superchain by default; no pre-existing superchain singleton addresses are required.
- Forge broadcast steps are bounded by timeout/retry checks so deploys fail fast instead of hanging indefinitely (`FORGE_BROADCAST_TIMEOUT_SECONDS`, `FORGE_BROADCAST_MAX_ATTEMPTS`, `FORGE_RETRY_SLEEP_SECONDS`, `FORGE_CONTRACT_WAIT_ATTEMPTS`).
- Bridge deployment predicts the next L2 bridge address first, deploys L1 with that predicted address, then deploys L2 and verifies the prediction match.
- `PRIVATE_KEY` values are normalized to `0x`-prefixed hex in runtime scripts, so either key format is accepted.

## Prerequisites

- `docker`, `docker compose`
- `jq`
- `cast` + `forge` (Foundry)
- `node` + `npm`
- `timeout` (Linux) or `gtimeout` (macOS with `coreutils`)
- Funded Sepolia accounts for:
  - deployer
  - sequencer
  - batch submitter
  - proposer
- Sepolia RPC + beacon RPC endpoints

## Manual Reference Flow (Advanced)

The remaining sections are a verbose manual walkthrough. This manual path reuses OP Sepolia singleton addresses unless you override them. If you want a fresh superchain every run, use `just deploy`.

## 1) Export Environment Variables

```bash
cd /path/to/example-cgt-bridge

export L1_RPC="https://your-sepolia-rpc"
export L1_BEACON="https://your-sepolia-beacon-rpc"

export DEPLOYER_KEY="0x..."
export SEQUENCER_KEY="0x..."
export BATCHER_KEY="0x..."
export PROPOSER_KEY="0x..."
```

## 2) Stop Existing Services

```bash
docker compose -f devnet/docker-compose.yml -p cgt-devnet down --remove-orphans -v || true
```

## 3) Bootstrap Fast Implementations (New OPCM)

```bash
export WORK_ROOT="$PWD/devnet/work"
mkdir -p "$WORK_ROOT"

export OP_DEPLOYER_IMAGE="us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2"

BOOT_ID="$(date -u +%Y%m%d-%H%M%S)"
BOOT_DIR="$WORK_ROOT/bootstrap-cgtv2-$BOOT_ID"
mkdir -p "$BOOT_DIR"

export DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_KEY")"
export SUPERCHAIN_CONFIG_PROXY="${SUPERCHAIN_CONFIG_PROXY:-0xC2Be75506d5724086DEB7245bd260Cc9753911Be}"
export PROTOCOL_VERSIONS_PROXY="${PROTOCOL_VERSIONS_PROXY:-0x79Add5713B383DAA0a138d3C4780C7A1804a8090}"
export SUPERCHAIN_PROXY_ADMIN="${SUPERCHAIN_PROXY_ADMIN:-0x189aBAAaA82DfC015A588A7dbaD6F13b1D3485Bc}"
export L1_PROXY_ADMIN_OWNER="${L1_PROXY_ADMIN_OWNER:-0x1Eb2fFc903729a0F03966B917003800b145F56E2}"
export CHALLENGER_ADDRESS="${CHALLENGER_ADDRESS:-$DEPLOYER_ADDRESS}"

docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$BOOT_DIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer bootstrap implementations \
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

export OPCM_ADDRESS="$(jq -r '.opcmAddress' "$BOOT_DIR/bootstrap-implementations.json")"
echo "OPCM_ADDRESS=$OPCM_ADDRESS"
```

## 4) Create Net-New Intent (Custom CGT)

```bash
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
WORKDIR="$WORK_ROOT/netnew-cgtv2-$RUN_ID"
mkdir -p "$WORKDIR"

# Unique chain id for this run
export L2_CHAIN_ID_DEC=$((300000000000000 + $(date -u +%s) + RANDOM))
export L2_CHAIN_ID_HEX="$(printf '0x%064x\n' "$L2_CHAIN_ID_DEC")"

export DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_KEY")"
export SEQUENCER_ADDRESS="$(cast wallet address --private-key "$SEQUENCER_KEY")"
export BATCHER_ADDRESS="$(cast wallet address --private-key "$BATCHER_KEY")"
export PROPOSER_ADDRESS="$(cast wallet address --private-key "$PROPOSER_KEY")"

docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$WORKDIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer init \
  --workdir /work \
  --intent-type custom \
  --l1-chain-id 11155111 \
  --l2-chain-ids "$L2_CHAIN_ID_DEC"

cp devnet/intent.toml.example "$WORKDIR/intent.toml"

sed -i "s|0xYOUR_BOOTSTRAPPED_OPCM_ADDRESS|$OPCM_ADDRESS|g" "$WORKDIR/intent.toml"
sed -i "s|0x00000000000000000000000000000000000000000000000000000000deadbeef|$L2_CHAIN_ID_HEX|g" "$WORKDIR/intent.toml"
sed -i "s|0xYOUR_ADDRESS|$DEPLOYER_ADDRESS|g" "$WORKDIR/intent.toml"
sed -i "s|0xYOUR_SEQUENCER_ADDRESS|$SEQUENCER_ADDRESS|g" "$WORKDIR/intent.toml"
sed -i "s|0xYOUR_BATCHER_ADDRESS|$BATCHER_ADDRESS|g" "$WORKDIR/intent.toml"
sed -i "s|0xYOUR_PROPOSER_ADDRESS|$PROPOSER_ADDRESS|g" "$WORKDIR/intent.toml"
```

## 5) Apply (Deploy L1 Contracts)

```bash
docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$WORKDIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer apply \
  --workdir /work \
  --l1-rpc-url "$L1_RPC" \
  --private-key "$DEPLOYER_KEY"
```

## 6) Validate CGT + Generate Runtime Artifacts

```bash
CHAIN_ID_HEX="$(jq -r '.appliedIntent.chains[0].id' "$WORKDIR/state.json")"
CHAIN_ID_DEC="$(cast to-dec "$CHAIN_ID_HEX")"

docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$WORKDIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer inspect deploy-config \
  --workdir /work \
  --outfile /work/deploy-config.json \
  "$CHAIN_ID_DEC"

jq '.useCustomGasToken,.faultGameMaxClockDuration,.faultGameClockExtension,.proofMaturityDelaySeconds,.disputeGameFinalityDelaySeconds' "$WORKDIR/deploy-config.json"

docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$WORKDIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer inspect genesis --workdir /work --outfile /work/genesis.json "$CHAIN_ID_DEC"

docker run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
  -v "$WORKDIR:/work" -w /work \
  "$OP_DEPLOYER_IMAGE" \
  op-deployer inspect rollup --workdir /work --outfile /work/rollup.json "$CHAIN_ID_DEC"

cp "$WORKDIR/genesis.json" devnet/genesis.json
cp "$WORKDIR/rollup.json" devnet/rollup.json
openssl rand -hex 32 > devnet/jwt.hex
openssl rand -hex 32 > devnet/p2p-key.txt
```

## 7) Build `devnet/.env`

```bash
DISPUTE_GAME_FACTORY="$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy' "$WORKDIR/state.json")"
BATCH_INBOX="$(jq -r '.batch_inbox_address' "$WORKDIR/rollup.json")"

cat > devnet/.env <<EONET
L1_RPC=$L1_RPC
L1_BEACON=$L1_BEACON
SEQUENCER_KEY=$SEQUENCER_KEY
BATCHER_KEY=$BATCHER_KEY
PROPOSER_KEY=$PROPOSER_KEY
L2_CHAIN_ID=$CHAIN_ID_DEC
DISPUTE_GAME_FACTORY=$DISPUTE_GAME_FACTORY
BATCH_INBOX=$BATCH_INBOX
OP_RETH_IMAGE=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-reth:v1.10.0
GENESIS_FILE=./genesis.json
ROLLUP_FILE=./rollup.json
JWT_FILE=./jwt.hex
P2P_KEY_FILE=./p2p-key.txt
L2_HTTP_PORT=19545
L2_WS_PORT=19546
L2_AUTH_PORT=19551
OP_NODE_RPC_PORT=17000
EONET
```

## 8) Start Docker Compose

```bash
(cd devnet && docker compose up -d)
(cd devnet && docker compose ps)
```

## 9) Verify Health + CGT Mode

```bash
source devnet/.env

cast chain-id --rpc-url "http://127.0.0.1:${L2_HTTP_PORT}"
cast block-number --rpc-url "http://127.0.0.1:${L2_HTTP_PORT}"
cast call 0x4200000000000000000000000000000000000015 'isCustomGasToken()(bool)' --rpc-url "http://127.0.0.1:${L2_HTTP_PORT}"

(cd devnet && docker compose ps)
(cd devnet && docker compose logs --tail=80 op-node)
(cd devnet && docker compose logs --tail=80 op-batcher)
(cd devnet && docker compose logs --tail=80 op-proposer)
```

`op-batcher` and `op-proposer` must stay healthy for timely withdrawal proving/finalization.
When running end-to-end bridge flows, use `scripts/withdraw.ts`; it includes explicit progress logs and `--resume-hash` support so long waits do not look stalled.

## 10) Verify Fast Overrides for Permissioned Dispute Game

```bash
source devnet/.env

PERMISSIONED_IMPL="$(cast call "$DISPUTE_GAME_FACTORY" 'gameImpls(uint32)(address)' 1 --rpc-url "$L1_RPC")"
PORTAL_PROXY="$(jq -r '.opChainDeployments[0].OptimismPortalProxy' "$WORKDIR/state.json")"

echo "permissionedImpl=$PERMISSIONED_IMPL"
cast call "$PERMISSIONED_IMPL" 'maxClockDuration()(uint64)' --rpc-url "$L1_RPC"
cast call "$PERMISSIONED_IMPL" 'clockExtension()(uint64)' --rpc-url "$L1_RPC"
cast call "$PORTAL_PROXY" 'proofMaturityDelaySeconds()(uint256)' --rpc-url "$L1_RPC"
cast call "$PORTAL_PROXY" 'disputeGameFinalityDelaySeconds()(uint256)' --rpc-url "$L1_RPC"
```

Expected values for this fast profile:

- `maxClockDuration = 15`
- `clockExtension = 5`
- `proofMaturityDelaySeconds = 15`
- `disputeGameFinalityDelaySeconds = 1`

## 11) Tear Down

```bash
(cd devnet && docker compose down --remove-orphans -v)
```
