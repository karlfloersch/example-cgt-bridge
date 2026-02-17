# CGT Devnet (Net-New + Docker Compose)

This is the canonical operator guide for running this repository end-to-end.

It deploys a brand-new superchain + brand-new CGT chain on Sepolia, starts local L2 services with Docker Compose, deploys the bridge pair, and validates deposit/withdraw.

## Quickstart (Recommended)

```bash
git clone --recurse-submodules https://github.com/karlfloersch/example-cgt-bridge.git
cd example-cgt-bridge

mise install
git submodule update --init --recursive
cp devnet/.env.deploy.example .env
# edit .env with your Sepolia RPC + funded keys
source .env

just deploy-chain
just deploy-bridge
just deposit-test 1
just withdraw-test 1
# optional resume if withdrawal was interrupted:
# just withdraw-test 1 0x<withdraw_tx_hash>
```

## Required Inputs

Provide these in `.env` (see `devnet/.env.deploy.example`):

- `L1_RPC`
- `L1_BEACON`
- `DEPLOYER_KEY`
- `SEQUENCER_KEY`
- `BATCHER_KEY`
- `PROPOSER_KEY`

## What The Commands Do

- `just deploy-chain`
- Stops existing local devnet containers.
- Bootstraps new superchain singletons and implementations.
- Creates and applies a net-new custom CGT chain intent.
- Starts `op-reth`, `op-node`, `op-batcher`, `op-proposer`.
- Validates CGT mode and fast permissioned dispute-game overrides.
- Writes chain metadata to `devnet/work/e2e-latest.env`.

- `just deploy-bridge`
- Reuses chain metadata from `devnet/work/e2e-latest.env`.
- Ensures compose services are up and re-validates fast permissioned dispute-game overrides.
- Deploys test L1 token + L1/L2 bridge pair.
- Writes `scripts/.env.runtime` and updates `devnet/work/e2e-latest.env`.

- `just deposit-test <amount>`
- Uses `scripts/.env.runtime` and runs an L1->L2 deposit test.

- `just withdraw-test <amount> [resume_hash]`
- Runs L2->L1 withdrawal prove/resolve/finalize with progress logging.

## Runtime Files Produced

After `just deploy-chain`, these are generated:

- `devnet/.env`
- `devnet/genesis.json`
- `devnet/rollup.json`
- `devnet/jwt.hex`
- `devnet/p2p-key.txt`
- `devnet/work/e2e-latest.env`

After `just deploy-bridge`, these are generated/updated:

- `scripts/.env.runtime`
- `devnet/work/e2e-latest.env`

## Override Validation (Permissioned Dispute Game)

`just deploy-chain` validates these values, and `just deploy-bridge` re-checks them. You can also verify manually:

```bash
source devnet/.env
source devnet/work/e2e-latest.env

PERMISSIONED_IMPL="$(cast call "$DISPUTE_GAME_FACTORY" 'gameImpls(uint32)(address)' 1 --rpc-url "$L1_RPC")"
cast call "$PERMISSIONED_IMPL" 'maxClockDuration()(uint64)' --rpc-url "$L1_RPC"
cast call "$PERMISSIONED_IMPL" 'clockExtension()(uint64)' --rpc-url "$L1_RPC"
cast call "$PORTAL_ADDRESS" 'proofMaturityDelaySeconds()(uint256)' --rpc-url "$L1_RPC"
cast call "$PORTAL_ADDRESS" 'disputeGameFinalityDelaySeconds()(uint256)' --rpc-url "$L1_RPC"
```

Expected:

- `maxClockDuration = 15`
- `clockExtension = 5`
- `proofMaturityDelaySeconds = 15`
- `disputeGameFinalityDelaySeconds = 1`

## Critical Notes

- `op-deployer` image is pinned for this flow: `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2`.
- `op-reth` image default: `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-reth:v1.10.0`.
- Withdrawal proving/finalization can still take a few minutes depending on proposer/batcher progress and Sepolia timing.
- `op-batcher` and `op-proposer` must remain healthy during withdrawal.
- Bridge deployment is intentionally ordered as:
  - predict next L2 bridge address
  - deploy L1 bridge with predicted L2 address
  - deploy L2 bridge and verify predicted/actual match
- Forge broadcast retries/timeouts are configurable via:
  - `FORGE_BROADCAST_TIMEOUT_SECONDS`
  - `FORGE_BROADCAST_MAX_ATTEMPTS`
  - `FORGE_RETRY_SLEEP_SECONDS`
  - `FORGE_CONTRACT_WAIT_ATTEMPTS`

## Optional: Run Deploy Command Directly

If you do not want to use `just`:

```bash
source .env
cd scripts
npx tsx deploy.ts chain
npx tsx deploy.ts bridge
```

## Teardown

```bash
(cd devnet && docker compose down --remove-orphans -v)
```
