/**
 * CGT Bridge — Withdrawal Demo (L2 → L1)
 *
 * Sends native asset to L2CGTBridge.withdraw(), then proves, resolves the
 * dispute game, and finalizes the withdrawal on L1. With fast finalization
 * config (15/15/1) this is usually quick, but can still take a few minutes
 * depending on proposer/batcher progress and Sepolia block timing.
 *
 * Usage:
 *   export L1_RPC=... L2_RPC=... PRIVATE_KEY=... (see .env.example)
 *   npx tsx withdraw.ts <amount> [--resume-hash <0xwithdrawTxHash>]
 *
 * <amount> is in human-readable token units (e.g. "100" for 100 tokens).
 * The script converts this to 18-decimal native asset on L2.
 */

import { formatUnits, parseUnits, type Hash } from "viem";
import { readContract } from "viem/actions";
import { getWithdrawals } from "viem/op-stack";
import {
  account,
  disputeGameAbi,
  erc20Abi,
  l1Public,
  l1Wallet,
  l2BridgeAbi,
  l2Public,
  l2Wallet,
  l2Chain,
  L1_TOKEN,
  L2_BRIDGE,
  TOKEN_DECIMALS,
  DISPUTE_GAME_FACTORY,
} from "./config.js";

const WITHDRAW_GAS_LIMIT = 200_000;
const RECEIPT_RETRY_DELAY_MS = 3_000;
const RECEIPT_MAX_ATTEMPTS = 20;
const RECEIPT_WAIT_TIMEOUT_MS = 25_000;
const GAME_POLL_INTERVAL_MS = 12_000;
const GAME_MAX_ATTEMPTS = 40;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function gameStatusLabel(status: number): string {
  if (status === 0) return "IN_PROGRESS";
  if (status === 1) return "CHALLENGER_WINS";
  if (status === 2) return "DEFENDER_WINS";
  return String(status);
}

async function waitForReceiptWithRetry(
  client: { waitForTransactionReceipt: (args: { hash: `0x${string}` }) => Promise<any> },
  hash: `0x${string}`,
  label: string,
) {
  for (let attempt = 1; attempt <= RECEIPT_MAX_ATTEMPTS; attempt++) {
    try {
      return await client.waitForTransactionReceipt({ hash, timeout: RECEIPT_WAIT_TIMEOUT_MS } as any);
    } catch (e: any) {
      const msg = String(e?.shortMessage ?? e?.message ?? "");
      const isNotFound =
        msg.includes("TransactionReceiptNotFound") ||
        msg.includes("could not be found");
      const isTimeout = msg.includes("Timed out while waiting for transaction");
      if ((!isNotFound && !isTimeout) || attempt === RECEIPT_MAX_ATTEMPTS) throw e;
      process.stdout.write(`\n${label} receipt pending (attempt ${attempt}/${RECEIPT_MAX_ATTEMPTS}), retrying...`);
      await sleep(RECEIPT_RETRY_DELAY_MS);
    }
  }
  throw new Error(`${label} receipt wait exhausted`);
}

const disputeGameFactoryAbi = [
  {
    type: "function",
    name: "gameAtIndex",
    inputs: [{ name: "_index", type: "uint256" }],
    outputs: [
      { name: "gameType_", type: "uint32" },
      { name: "timestamp_", type: "uint64" },
      { name: "proxy_", type: "address" },
    ],
    stateMutability: "view",
  },
] as const;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const humanAmount = process.argv[2];
  if (!humanAmount) {
    console.error("Usage: npx tsx withdraw.ts <amount> [--resume-hash <0xwithdrawTxHash>]");
    console.error("  <amount>  Token amount in human units (e.g. 100)");
    process.exit(1);
  }
  const resumeHashFlagIndex = process.argv.indexOf("--resume-hash");
  const resumeHash =
    resumeHashFlagIndex >= 0 ? (process.argv[resumeHashFlagIndex + 1] as Hash | undefined) : undefined;
  if (resumeHashFlagIndex >= 0 && !resumeHash) {
    console.error("Missing value for --resume-hash");
    process.exit(1);
  }

  const l1Amount = parseUnits(humanAmount, TOKEN_DECIMALS);
  const scaleFactor = 10n ** BigInt(18 - TOKEN_DECIMALS);
  const l2Value = l1Amount * scaleFactor;
  const recipient = account.address;

  console.log(`Withdrawing ${humanAmount} tokens`);
  console.log(`  L2 value (18 dec): ${formatUnits(l2Value, 18)}`);
  console.log(`  L1 amount (${TOKEN_DECIMALS} dec): ${formatUnits(l1Amount, TOKEN_DECIMALS)}`);
  console.log(`  Recipient: ${recipient}`);
  console.log("  Note: Withdrawal proving/finalization can take several minutes depending on proposer/batcher progress.");
  console.log();

  // -----------------------------------------------------------------------
  // Step 1: Initiate withdrawal on L2
  // -----------------------------------------------------------------------
  let withdrawHash: Hash;
  if (resumeHash) {
    console.log("1. Reusing existing withdrawal tx on L2...");
    withdrawHash = resumeHash;
    console.log(`   tx: ${withdrawHash}`);
  } else {
    console.log("1. Sending withdrawal tx on L2...");
    withdrawHash = await l2Wallet.writeContract({
      address: L2_BRIDGE,
      abi: l2BridgeAbi,
      functionName: "withdraw",
      args: [recipient, WITHDRAW_GAS_LIMIT],
      value: l2Value,
      chain: l2Chain as any,
    });
    console.log(`   tx: ${withdrawHash}`);
  }

  const withdrawReceipt = await waitForReceiptWithRetry(
    l2Public as any,
    withdrawHash,
    "Withdraw",
  );
  if (withdrawReceipt.status === "reverted") {
    console.error("   Withdrawal transaction reverted!");
    process.exit(1);
  }
  console.log(`   confirmed in block ${withdrawReceipt.blockNumber}.`);

  // -----------------------------------------------------------------------
  // Step 2: Wait for a dispute game covering the withdrawal block
  // -----------------------------------------------------------------------
  console.log("\n2. Waiting for op-proposer to create a dispute game...");
  const [withdrawal] = getWithdrawals({ logs: withdrawReceipt.logs as any });
  if (!withdrawal) throw new Error("No withdrawal message found in L2 receipt");

  let game: any | undefined;
  for (let attempt = 1; attempt <= GAME_MAX_ATTEMPTS; attempt++) {
    try {
      game = await (l1Public as any).getGame({
        l2BlockNumber: withdrawReceipt.blockNumber,
        targetChain: l2Chain,
      });
      break;
    } catch (e: any) {
      const msg = String(e?.shortMessage ?? e?.message ?? "");
      const retryable =
        msg.includes("GameNotFound") ||
        msg.includes("No game") ||
        msg.includes("game not found") ||
        msg.includes("Dispute game not found") ||
        msg.includes("could not find a game");
      if (!retryable || attempt === GAME_MAX_ATTEMPTS) throw e;
      console.log(`   Waiting for game... attempt ${attempt}/${GAME_MAX_ATTEMPTS}`);
      await sleep(GAME_POLL_INTERVAL_MS);
    }
  }
  if (!game) throw new Error("Timed out waiting for dispute game");
  const output = {
    l2BlockNumber: game.l2BlockNumber,
    outputIndex: game.index,
    outputRoot: game.rootClaim,
    timestamp: game.timestamp,
  };

  // Get game proxy address from the DGF
  const [, , gameAddress] = await readContract(l1Public, {
    address: DISPUTE_GAME_FACTORY,
    abi: disputeGameFactoryAbi,
    functionName: "gameAtIndex",
    args: [game.index],
  });
  console.log(`   Game found at index ${game.index}: ${gameAddress}`);

  // Wait for at least one L1 block after game creation — the portal requires
  // block.timestamp > game.createdAt() to prevent proving in the same block.
  console.log("   Waiting for next L1 block (portal requires proof in a later block)...");
  await sleep(15_000);

  // -----------------------------------------------------------------------
  // Step 3: Prove the withdrawal on L1
  // -----------------------------------------------------------------------
  console.log("\n3. Building withdrawal proof (from L2 state)...");
  const proveArgs = await (l2Public as any).buildProveWithdrawal({
    output,
    game,
    withdrawal,
  });

  console.log("   Proving withdrawal on L1...");
  const proveHash: Hash = await (l1Wallet as any).proveWithdrawal(proveArgs);
  console.log(`   tx: ${proveHash}`);
  await waitForReceiptWithRetry(l1Public as any, proveHash, "Prove");
  console.log("   confirmed.");

  // -----------------------------------------------------------------------
  // Step 4: Wait for game clock to expire, then resolve
  // -----------------------------------------------------------------------
  console.log("\n4. Waiting for game clock to expire (faultGameMaxClockDuration)...");

  // Poll until resolveClaim succeeds (ClockNotExpired = 0xf2440b53)
  let resolveClaimHash: Hash | undefined;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      // Simulate first to avoid wasting gas on reverts
      await l1Public.simulateContract({
        account,
        address: gameAddress,
        abi: disputeGameAbi,
        functionName: "resolveClaim",
        args: [0n, 512n],
      });
      // Simulation passed — send the real tx
      resolveClaimHash = await l1Wallet.writeContract({
        address: gameAddress,
        abi: disputeGameAbi,
        functionName: "resolveClaim",
        args: [0n, 512n],
      });
      break;
    } catch (e: any) {
      const msg = e?.cause?.raw ?? e?.message ?? "";
      if ((typeof msg === "string" && msg.includes("f2440b53")) || e?.cause?.signature === "0xf2440b53") {
        console.log(`   Game clock not expired yet, retrying resolveClaim (${attempt + 1}/20)`);
        await sleep(12_000); // wait one Sepolia block
        continue;
      }
      throw e;
    }
  }
  if (!resolveClaimHash) throw new Error("resolveClaim timed out (clock never expired)");

  await waitForReceiptWithRetry(l1Public as any, resolveClaimHash, "resolveClaim");
  console.log(`\n   resolveClaim tx: ${resolveClaimHash}`);

  console.log("   Resolving game...");
  let gameStatus = Number(await l1Public.readContract({
    address: gameAddress,
    abi: disputeGameAbi,
    functionName: "status",
  }));
  for (let attempt = 1; attempt <= 20 && gameStatus === 0; attempt++) {
    try {
      const resolveHash = await l1Wallet.writeContract({
        address: gameAddress,
        abi: disputeGameAbi,
        functionName: "resolve",
        args: [],
      });
      console.log(`   resolve tx: ${resolveHash} (attempt ${attempt}/20)`);
      await waitForReceiptWithRetry(l1Public as any, resolveHash, "Resolve");
    } catch (e: any) {
      const msg = String(e?.shortMessage ?? e?.message ?? e);
      console.log(`   resolve attempt ${attempt}/20 failed (${msg}).`);
    }

    gameStatus = Number(await l1Public.readContract({
      address: gameAddress,
      abi: disputeGameAbi,
      functionName: "status",
    }));
    if (gameStatus !== 0) {
      break;
    }
    if (attempt < 20) {
      console.log("   game still IN_PROGRESS, retrying resolve...");
      await sleep(12_000);
    }
  }

  // 0 = IN_PROGRESS, 1 = CHALLENGER_WINS, 2 = DEFENDER_WINS
  console.log(`   game status: ${gameStatusLabel(gameStatus)}`);
  if (gameStatus !== 2) {
    throw new Error(`Cannot finalize withdrawal: dispute game status is ${gameStatusLabel(gameStatus)}`);
  }

  // -----------------------------------------------------------------------
  // Step 5: Wait for finality delays
  // -----------------------------------------------------------------------
  // -----------------------------------------------------------------------
  // Step 5+6: Wait for finality delays and finalize
  // -----------------------------------------------------------------------
  console.log("\n5. Waiting for finality delays, then finalizing...");
  // proofMaturityDelaySeconds = 15, disputeGameFinalityDelaySeconds = 1
  // Poll until finalizeWithdrawal succeeds (may need to wait for on-chain timestamps).
  await sleep(18_000); // initial wait for proof maturity

  let finalizeHash: Hash | undefined;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      const candidateHash: Hash = await (l1Wallet as any).finalizeWithdrawal({
        targetChain: l2Chain,
        withdrawal,
      });
      console.log(`\n   finalize tx: ${candidateHash} (attempt ${attempt + 1}/20)`);
      await waitForReceiptWithRetry(l1Public as any, candidateHash, "Finalize");
      finalizeHash = candidateHash;
      break;
    } catch (e: any) {
      const msg = String(e?.cause?.raw ?? e?.shortMessage ?? e?.message ?? "");
      // Retry on timing-related errors (proof not mature, game not finalized)
      if (
        msg.includes("ProposalNotValidated") ||
        msg.includes("maturity") ||
        msg.includes("Finality") ||
        msg.includes("0x332a57f8") ||
        msg.includes("Timed out while waiting for transaction") ||
        msg.includes("TransactionReceiptNotFound")
      ) {
        console.log(`   Finalize not ready yet, retrying (${attempt + 1}/20)`);
        await sleep(12_000);
        continue;
      }
      throw e;
    }
  }
  if (!finalizeHash) throw new Error("finalizeWithdrawal timed out");
  console.log("   confirmed.");

  // -----------------------------------------------------------------------
  // Verify
  // -----------------------------------------------------------------------
  const l1Balance = await l1Public.readContract({
    address: L1_TOKEN,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [recipient],
  });
  console.log(`\nL1 token balance: ${formatUnits(l1Balance as bigint, TOKEN_DECIMALS)}`);
  console.log("Done. Withdrawal complete.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
