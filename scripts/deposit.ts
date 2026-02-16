/**
 * CGT Bridge — Deposit Demo (L1 → L2)
 *
 * Approves the L1 bridge to spend tokens, deposits them, and polls L2
 * until the native asset balance increases.
 *
 * Usage:
 *   export L1_RPC=... L2_RPC=... PRIVATE_KEY=... (see .env.example)
 *   npx tsx deposit.ts <amount>
 *
 * <amount> is in human-readable token units (e.g. "100" for 100 tokens).
 */

import { formatUnits, parseUnits } from "viem";
import {
  account,
  erc20Abi,
  l1BridgeAbi,
  l1Public,
  l1Wallet,
  l2Public,
  L1_BRIDGE,
  L1_TOKEN,
  TOKEN_DECIMALS,
} from "./config.js";

const CROSS_CHAIN_GAS_LIMIT = 200_000;
const TX_GAS_LIMIT = 500_000n;
const POLL_INTERVAL_MS = 2_000;
const RECEIPT_RETRY_DELAY_MS = 3_000;
const RECEIPT_MAX_ATTEMPTS = 40;

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForReceiptWithRetry(hash: `0x${string}`, label: string) {
  for (let attempt = 1; attempt <= RECEIPT_MAX_ATTEMPTS; attempt++) {
    try {
      return await l1Public.waitForTransactionReceipt({ hash });
    } catch (e: any) {
      const msg = String(e?.shortMessage ?? e?.message ?? "");
      const isNotFound =
        msg.includes("TransactionReceiptNotFound") ||
        msg.includes("could not be found");
      if (!isNotFound || attempt === RECEIPT_MAX_ATTEMPTS) throw e;
      process.stdout.write(`\n${label} receipt not available yet (attempt ${attempt}/${RECEIPT_MAX_ATTEMPTS}), retrying...`);
      await sleep(RECEIPT_RETRY_DELAY_MS);
    }
  }
  throw new Error(`${label} receipt wait exhausted`);
}

async function main() {
  const humanAmount = process.argv[2];
  if (!humanAmount) {
    console.error("Usage: npx tsx deposit.ts <amount>");
    console.error("  <amount>  Token amount in human units (e.g. 100)");
    process.exit(1);
  }

  const amount = parseUnits(humanAmount, TOKEN_DECIMALS);
  const recipient = account.address;

  console.log(`Depositing ${humanAmount} tokens (${amount} raw) to ${recipient}`);
  console.log(`  L1 Token:  ${L1_TOKEN}`);
  console.log(`  L1 Bridge: ${L1_BRIDGE}`);
  console.log();

  // -----------------------------------------------------------------------
  // 1. Check L1 token balance
  // -----------------------------------------------------------------------
  const l1Balance = await l1Public.readContract({
    address: L1_TOKEN,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [recipient],
  });
  console.log(`L1 token balance: ${formatUnits(l1Balance as bigint, TOKEN_DECIMALS)}`);
  if ((l1Balance as bigint) < amount) {
    console.error("Insufficient L1 token balance.");
    process.exit(1);
  }

  // -----------------------------------------------------------------------
  // 2. Snapshot L2 balance before deposit (avoids race if deposit lands fast)
  // -----------------------------------------------------------------------
  const l2BalanceBefore = await l2Public.getBalance({ address: recipient });
  console.log(`L2 balance before: ${formatUnits(l2BalanceBefore, 18)}`);

  // -----------------------------------------------------------------------
  // 3. Approve L1 bridge to spend tokens
  // -----------------------------------------------------------------------
  console.log("Approving L1 bridge...");
  const approveHash = await l1Wallet.writeContract({
    address: L1_TOKEN,
    abi: erc20Abi,
    functionName: "approve",
    args: [L1_BRIDGE, amount],
  });
  console.log(`  tx: ${approveHash}`);
  await waitForReceiptWithRetry(approveHash, "Approve");
  console.log("  confirmed.");

  // -----------------------------------------------------------------------
  // 4. Deposit
  // -----------------------------------------------------------------------
  console.log("Depositing...");
  const depositHash = await l1Wallet.writeContract({
    address: L1_BRIDGE,
    abi: l1BridgeAbi,
    functionName: "deposit",
    args: [recipient, amount, CROSS_CHAIN_GAS_LIMIT],
    gas: TX_GAS_LIMIT,
  });
  console.log(`  tx: ${depositHash}`);
  const depositReceipt = await waitForReceiptWithRetry(depositHash, "Deposit");
  if (depositReceipt.status === "reverted") {
    console.error("  Deposit transaction reverted!");
    process.exit(1);
  }
  console.log("  confirmed on L1.");

  // -----------------------------------------------------------------------
  // 5. Poll L2 balance until deposit is relayed
  // -----------------------------------------------------------------------
  const scaleFactor = 10n ** BigInt(18 - TOKEN_DECIMALS);
  const expectedL2Increase = amount * scaleFactor;

  console.log();
  console.log(`Waiting for L2 deposit relay (expecting +${formatUnits(expectedL2Increase, 18)} native)...`);

  while (true) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    const l2Balance = await l2Public.getBalance({ address: recipient });
    if (l2Balance > l2BalanceBefore) {
      const increase = l2Balance - l2BalanceBefore;
      console.log(`\nDeposit landed on L2! Balance increased by ${formatUnits(increase, 18)} native.`);
      console.log(`L2 balance: ${formatUnits(l2Balance, 18)}`);
      break;
    }
    process.stdout.write(".");
  }

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
