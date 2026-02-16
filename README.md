# CGT Decimal Bridge

A reference bridge for Custom Gas Token (CGT) chains that handles decimal scaling between an L1 ERC-20 token (e.g., 6 decimals) and the L2 native asset (18 decimals).

## Overview

CGT chains use a custom ERC-20 as their native gas token instead of ETH. The native asset on L2 always has 18 decimals, but the underlying L1 token may have fewer (e.g., 6 or 8 decimals). This bridge handles the decimal conversion automatically.

**How it works:**

- **Deposit (L1 → L2):** User locks L1 tokens in `L1CGTBridge`. A cross-chain message tells `L2CGTBridge` to mint the equivalent amount of native asset on L2, scaled up to 18 decimals.
- **Withdraw (L2 → L1):** User sends native asset to `L2CGTBridge`, which burns it and sends a cross-chain message to release the equivalent L1 tokens from `L1CGTBridge`, scaled back down.
- **Scale factor:** `10^(18 - tokenDecimals)`. For a 6-decimal token, 1 token on L1 (1,000,000 raw) becomes 1 native token on L2 (1,000,000,000,000,000,000 wei).

## Contracts

| Contract | Chain | Description |
|----------|-------|-------------|
| `L1CGTBridge` | L1 | Locks/releases L1 ERC-20 tokens |
| `L2CGTBridge` | L2 | Mints/burns native asset via `LiquidityController` |

Both contracts are deployed with `new` (CREATE, not CREATE2) and take the other's address as an immutable constructor argument.

## Part 1: Deploy a CGT Chain

Before deploying the bridge, you need a running CGT chain. Use the reproducible workflow in `devnet/README.md`.

Fast path (recommended):

```bash
mise install
cp devnet/.env.deploy.example .env
# edit .env with RPC + keys
source .env

just deploy
```

This boots a brand-new superchain + brand-new chain, starts Docker Compose, deploys a test token + bridge pair, and writes `scripts/.env.runtime` so the test commands can run immediately.

Then run bridge tests:

```bash
just deposit-test 1
just withdraw-test 1
# optional resume:
# just withdraw-test 1 0x<withdraw_tx_hash>
```

Keep in mind:

- Pin `op-deployer` to `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2`.
- Use `intent-type custom` / `configType = "custom"` for CGT.
- For `bootstrap implementations`, include superchain proxy flags and `--challenger`.
- If `opcmAddress` is set in custom intent, do **not** include `[superchainRoles]`.
- Keep `op-batcher` and `op-proposer` healthy; they are required for withdrawal proving/finalization.

`devnet/README.md` contains the exact commands, compose settings, and override validation steps used in this repository.

## Part 2: Deploy the Bridge

### Prerequisites

1. **A running CGT chain** (Part 1 above).
2. **An L1 ERC-20 token** — the token your CGT chain uses as its gas token. Must have fewer than 18 decimals.
3. **A deployer wallet** — with funds on both L1 and L2.

### Step 1: Set environment variables

```bash
# L1 configuration
export L1_RPC="https://your-l1-rpc"
export L1_TOKEN="0x..."           # Your L1 ERC-20 token address
export L1_MESSENGER="0x..."       # L1CrossDomainMessenger (from op-deployer state.json)
export DECIMALS=6                 # Your token's decimal count (must be < 18)

# L2 configuration
export L2_RPC="http://your-l2-rpc"
export L2_MESSENGER="0x4200000000000000000000000000000000000007"
export LIQUIDITY_CONTROLLER="0x420000000000000000000000000000000000002a"

# Deployer
export DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)
```

### Step 2: Predict the L2CGTBridge address

```bash
L2_NONCE=$(cast nonce $DEPLOYER --rpc-url $L2_RPC)
L2_BRIDGE_PREDICTED=$(cast compute-address $DEPLOYER --nonce $L2_NONCE | rg -o '0x[a-fA-F0-9]{40}' | tail -n1)
echo "Predicted L2CGTBridge: $L2_BRIDGE_PREDICTED"
```

This works because CREATE addresses depend only on deployer + nonce, not on constructor args.

### Step 3: Deploy L1CGTBridge on L1

```bash
forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL1 \
  --sig "run(address,uint8,address,address)" \
  $L1_TOKEN $DECIMALS $L2_BRIDGE_PREDICTED $L1_MESSENGER \
  --rpc-url $L1_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Save the deployed L1CGTBridge address from the output:

```bash
export L1_BRIDGE="0x..."  # from script output
```

### Step 4: Deploy L2CGTBridge on L2

```bash
forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL2 \
  --sig "run(address,address,uint8,address)" \
  $L1_BRIDGE $L2_MESSENGER $DECIMALS $LIQUIDITY_CONTROLLER \
  --rpc-url $L2_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Save the deployed L2CGTBridge address from the output and verify it matches the prediction from Step 2:

```bash
export L2_BRIDGE="0x..."  # from script output
[[ "${L2_BRIDGE,,}" == "${L2_BRIDGE_PREDICTED,,}" ]] && echo "L2 address prediction matched"
```

If it does not match, stop and redeploy both bridges from a fresh run.

### Step 5: Authorize L2CGTBridge as a minter

The L2CGTBridge needs permission to mint/burn native asset via LiquidityController. This must be called by the LiquidityController owner (set during chain genesis).

```bash
forge script script/DeployCGTBridge.s.sol:DeployCGTBridgeL2 \
  --sig "authorizeMinter(address,address)" \
  $LIQUIDITY_CONTROLLER $L2_BRIDGE \
  --rpc-url $L2_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Step 6: Verify the deployment

```bash
# Check bridges point to each other
cast call $L1_BRIDGE "OTHER_BRIDGE()(address)" --rpc-url $L1_RPC
cast call $L2_BRIDGE "OTHER_BRIDGE()(address)" --rpc-url $L2_RPC

# Check L2CGTBridge is authorized as minter
cast call $LIQUIDITY_CONTROLLER "minters(address)(bool)" $L2_BRIDGE --rpc-url $L2_RPC

# Check decimal configuration
cast call $L1_BRIDGE "TOKEN_DECIMALS()(uint8)" --rpc-url $L1_RPC
cast call $L2_BRIDGE "TOKEN_DECIMALS()(uint8)" --rpc-url $L2_RPC
cast call $L2_BRIDGE "DECIMAL_SCALE_FACTOR()(uint256)" --rpc-url $L2_RPC
```

## Part 3: Use the Bridge

### Deposit (L1 → L2)

```bash
AMOUNT=100000000  # 100 tokens (6 decimals)
RECIPIENT="0x..."
GAS_LIMIT=200000

# 1. Approve the bridge to spend your tokens
cast send $L1_TOKEN "approve(address,uint256)" $L1_BRIDGE $AMOUNT \
  --private-key $PRIVATE_KEY --rpc-url $L1_RPC

# 2. Deposit
cast send $L1_BRIDGE "deposit(address,uint256,uint32)" $RECIPIENT $AMOUNT $GAS_LIMIT \
  --private-key $PRIVATE_KEY --rpc-url $L1_RPC
```

The deposit message is relayed automatically by the L2 node. The recipient receives `AMOUNT * 10^(18 - DECIMALS)` wei of native asset on L2.

### Withdraw (L2 → L1)

```bash
RECIPIENT="0x..."
GAS_LIMIT=200000
VALUE=100000000000000000000  # 100 tokens in 18 decimals (100 * 10^18 wei)

cast send $L2_BRIDGE "withdraw(address,uint32)" $RECIPIENT $GAS_LIMIT \
  --value $VALUE \
  --private-key $PRIVATE_KEY --rpc-url $L2_RPC
```

The withdrawal must be proven and finalized on L1 through the OptimismPortal (standard OP Stack withdrawal flow). The L1 recipient receives `VALUE / 10^(18 - DECIMALS)` of the L1 token.

**Important:** The withdrawal value must be exactly divisible by the scale factor. For a 6-decimal token, the value must be divisible by `10^12`. The contract reverts if it isn't.
**Timing note:** Even with the fast dispute game profile used in this repo, withdrawal proving/finalization can still take a few minutes depending on `op-proposer` / `op-batcher` progress and Sepolia block timing.
**Operator note:** Prefer using `scripts/withdraw.ts` for end-to-end withdrawals. It emits explicit retry/progress logs and supports `--resume-hash <withdrawTxHash>` so a restarted run can continue from an existing L2 withdrawal tx.

## Decimal Scaling Examples

| L1 Token Decimals | Scale Factor | L1 Amount | L2 Amount (wei) |
|-------------------|-------------|-----------|-----------------|
| 6 | 10^12 | 1,000,000 (1 token) | 1,000,000,000,000,000,000 (1 ether) |
| 6 | 10^12 | 100,000,000 (100 tokens) | 100,000,000,000,000,000,000 (100 ether) |
| 8 | 10^10 | 100,000,000 (1 token) | 1,000,000,000,000,000,000 (1 ether) |
| 2 | 10^16 | 100 (1 token) | 1,000,000,000,000,000,000 (1 ether) |

## End-to-End Demo

Want to see the full flow in action? The `devnet/` directory contains everything you need to:

1. Bootstrap a new superchain and deploy a net-new CGT chain on Sepolia
2. Spin up L2 services (op-reth, op-node, op-batcher, op-proposer) via Docker Compose
3. Deploy a test ERC-20 plus the bridge pair
4. Run a deposit (L1 → L2) and withdrawal (L2 → L1) tests

See [devnet/README.md](devnet/README.md) for the full walkthrough.

```
devnet/
├── README.md               # Step-by-step guide
├── .env.deploy.example     # Deploy-time environment template
├── scripts/                # Automation scripts used by justfile
├── docker-compose.yml       # L2 services (op-reth, op-node, op-batcher, op-proposer)
├── .env.example             # Environment variable template
└── intent.toml.example      # op-deployer intent with CGT + fast finalization

scripts/
├── deposit.ts               # Deposit demo (approve → deposit → poll L2)
├── withdraw.ts              # Withdrawal demo (withdraw → prove → resolve → finalize)
├── config.ts                # Shared chain definition and viem clients
├── package.json             # viem + tsx dependencies
└── tsconfig.json

justfile                     # 3-command operator flow (deploy/deposit-test/withdraw-test)
mise.toml                    # Toolchain pinning for reproducible setup
```

## Security Considerations

- These contracts are **illustrative examples**, not production protocol contracts.
- Fee-on-transfer and rebasing tokens are **not supported** and will cause accounting mismatches.
- The `L1CGTBridge` does not verify that `_l1Token` matches the CGT chain's actual gas token. The deployer is responsible for using the correct token.
- Only the LiquidityController owner can authorize minters. Ensure this role is properly secured.
