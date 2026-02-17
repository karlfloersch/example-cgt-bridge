# CGT Decimal Bridge Example

This repository demonstrates a Custom Gas Token (CGT) bridge and includes a fully reproducible end-to-end devnet workflow.

## Start Here (Recommended)

If you want to deploy a brand-new chain and run deposit/withdraw tests, use this flow:

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
# optional resume if a withdrawal run was interrupted:
# just withdraw-test 1 0x<withdraw_tx_hash>
```

## Which Guide To Follow?

- Use `devnet/README.md` if you want the full reproducible workflow (new superchain + new chain + Docker services + bridge + tests).
- Use `script/DeployCGTBridge.s.sol` and contract docs only if you already have an existing CGT chain and only need bridge deployment mechanics.

## What `just deploy-chain` Does

- Stops old local compose services.
- Bootstraps a new superchain and implementations.
- Deploys a net-new custom intent chain on Sepolia.
- Starts `op-reth`, `op-node`, `op-batcher`, `op-proposer` via Docker Compose.
- Validates fast permissioned dispute-game overrides.
- Writes chain runtime metadata to `devnet/work/e2e-latest.env`.

## What `just deploy-bridge` Does

- Reuses the latest chain metadata from `devnet/work/e2e-latest.env`.
- Verifies services are up and re-checks fast permissioned dispute-game overrides.
- Deploys a test L1 token and bridge pair.
- Writes `scripts/.env.runtime` for deposit/withdraw scripts.

## Bridge Overview

Contracts:

- `L1CGTBridge`: locks/releases L1 ERC-20 tokens.
- `L2CGTBridge`: mints/burns L2 native asset via `LiquidityController`.

Flow:

- Deposit (L1 -> L2): lock L1 tokens, mint scaled L2 native asset.
- Withdraw (L2 -> L1): burn L2 native asset, release scaled L1 tokens.

Scale factor:

- `10^(18 - tokenDecimals)`
- Example for 6-decimal token: `1_000_000` (L1 raw) <-> `1e18` wei (L2).

## Critical Notes

- Withdrawal proving/finalization can take a few minutes even with fast overrides.
- Keep `op-batcher` and `op-proposer` healthy for withdrawal progress.
- Use `scripts/withdraw.ts` (via `just withdraw-test`) for progress logs and resume support.
- This repo is an example implementation, not production bridge infrastructure.

## Repository Layout

- `devnet/README.md`: canonical step-by-step operational guide.
- `devnet/scripts/`: deposit/withdraw wrappers.
- `scripts/`: TypeScript deploy + deposit/withdraw flows.
- `src/`: bridge/token contracts.
- `script/`: Forge deployment scripts.
- `justfile`: primary operator commands.
