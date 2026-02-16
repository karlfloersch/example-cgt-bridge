import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { chainConfig, publicActionsL1, publicActionsL2, walletActionsL1 } from "viem/op-stack";

// ---------------------------------------------------------------------------
// Required environment variables
// ---------------------------------------------------------------------------
function env(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing env var: ${name}`);
    process.exit(1);
  }
  return v;
}

function envAddress(name: string): Address {
  return env(name) as Address;
}

function envPrivateKey(name: string): `0x${string}` {
  const raw = env(name).trim();
  const normalized = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
    console.error(`Invalid private key format in ${name}: expected 32-byte hex (with or without 0x prefix)`);
    process.exit(1);
  }
  return normalized as `0x${string}`;
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
export const L1_RPC = env("L1_RPC");
export const L2_RPC = env("L2_RPC");
export const PRIVATE_KEY = envPrivateKey("PRIVATE_KEY");
export const L2_CHAIN_ID = Number(env("L2_CHAIN_ID"));

// Bridge addresses (deployed via Forge scripts)
export const L1_BRIDGE = envAddress("L1_BRIDGE");
export const L2_BRIDGE = envAddress("L2_BRIDGE");
export const L1_TOKEN = envAddress("L1_TOKEN");
export const TOKEN_DECIMALS = Number(env("TOKEN_DECIMALS"));

// OP Stack contract addresses (from op-deployer state.json)
export const DISPUTE_GAME_FACTORY = envAddress("DISPUTE_GAME_FACTORY");
export const PORTAL_ADDRESS = envAddress("PORTAL_ADDRESS");

// ---------------------------------------------------------------------------
// Chain definition
// ---------------------------------------------------------------------------
export const l2Chain = defineChain({
  ...chainConfig,
  id: L2_CHAIN_ID,
  name: "CGT Devnet",
  nativeCurrency: { name: "CGT", symbol: "CGT", decimals: 18 },
  rpcUrls: { default: { http: [L2_RPC] } },
  sourceId: sepolia.id,
  contracts: {
    ...chainConfig.contracts,
    disputeGameFactory: {
      [sepolia.id]: { address: DISPUTE_GAME_FACTORY },
    },
    portal: {
      [sepolia.id]: { address: PORTAL_ADDRESS },
    },
  },
});

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------
export const account = privateKeyToAccount(PRIVATE_KEY);

export const l1Public = createPublicClient({
  chain: sepolia,
  transport: http(L1_RPC),
}).extend(publicActionsL1());

export const l2Public = createPublicClient({
  chain: l2Chain as any,
  transport: http(L2_RPC),
}).extend(publicActionsL2());

export const l1Wallet = createWalletClient({
  account,
  chain: sepolia,
  transport: http(L1_RPC),
}).extend(walletActionsL1());

export const l2Wallet = createWalletClient({
  account,
  chain: l2Chain as any,
  transport: http(L2_RPC),
});

// ---------------------------------------------------------------------------
// ABI fragments
// ---------------------------------------------------------------------------
export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

export const l1BridgeAbi = [
  {
    type: "function",
    name: "deposit",
    inputs: [
      { name: "_to", type: "address" },
      { name: "_amount", type: "uint256" },
      { name: "_minGasLimit", type: "uint32" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

export const l2BridgeAbi = [
  {
    type: "function",
    name: "withdraw",
    inputs: [
      { name: "_to", type: "address" },
      { name: "_minGasLimit", type: "uint32" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

export const disputeGameAbi = [
  {
    type: "function",
    name: "resolveClaim",
    inputs: [
      { name: "_claimIndex", type: "uint256" },
      { name: "_numToResolve", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "resolve",
    inputs: [],
    outputs: [{ name: "status_", type: "uint8" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "status",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
] as const;
