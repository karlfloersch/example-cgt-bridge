import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

type DeployPhase = "chain" | "bridge" | "all";

type DeployContext = {
  chainDir: string;
  superchainDir: string;
  implementationsDir: string;
  chainIdDec: string;
  disputeGameFactory: string;
  portalProxy: string;
  l1Messenger: string;
  l2RpcUrl: string;
};

type RunOpts = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  stdio?: "inherit" | "pipe";
};

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");
const DEVNET_DIR = path.join(ROOT_DIR, "devnet");
const WORK_ROOT_DEFAULT = path.join(DEVNET_DIR, "work");
const E2E_LATEST_ENV = path.join(WORK_ROOT_DEFAULT, "e2e-latest.env");

const LIQUIDITY_CONTROLLER_PREDEPLOY = "0x420000000000000000000000000000000000002a";
const L2_MESSENGER_PREDEPLOY = "0x4200000000000000000000000000000000000007";
const IS_CUSTOM_GAS_TOKEN_PREDEPLOY = "0x4200000000000000000000000000000000000015";
const DEFAULT_DEV_FUNDED_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;
const sleeper = new Int32Array(new SharedArrayBuffer(4));

function sleep(ms: number): void {
  Atomics.wait(sleeper, 0, 0, ms);
}

function nowTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function nowRunId(): string {
  const d = new Date();
  const pad = (n: number): string => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`;
}

function log(msg: string): void {
  console.log(`\n[${nowTimestamp()}] ${msg}`);
}

function die(msg: string): never {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
}

function run(command: string, args: string[], opts: RunOpts = {}): SpawnSyncReturns<string> {
  return spawnSync(command, args, {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    stdio: opts.stdio ?? "inherit",
    encoding: "utf8",
  });
}

function runOrDie(command: string, args: string[], opts: RunOpts = {}): string {
  const result = run(command, args, { ...opts, stdio: opts.stdio ?? "pipe" });
  if (result.error) {
    die(`Failed to run '${command}': ${result.error.message}`);
  }
  if (result.status !== 0) {
    const stderr = (result.stderr ?? "").trim();
    die(`Command failed (${command} ${args.join(" ")}): ${stderr || `exit ${String(result.status)}`}`);
  }
  return (result.stdout ?? "").trim();
}

function commandExists(command: string): boolean {
  const result = run("which", [command], { stdio: "pipe" });
  return result.status === 0;
}

function requireCmd(command: string): void {
  if (!commandExists(command)) {
    die(`Missing required command: ${command}`);
  }
}

function requireDockerComposePlugin(): void {
  const result = run("docker", ["compose", "version"], { stdio: "pipe" });
  if (result.status !== 0) {
    die("Missing docker compose plugin");
  }
}

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    die(`Missing required environment variable: ${name}`);
  }
  return value;
}

function parseUIntString(name: string, rawValue: string): bigint {
  if (!/^\d+$/.test(rawValue)) {
    die(`${name} must be an integer`);
  }
  return BigInt(rawValue);
}

function normalizePrivateKey(name: string, rawValue: string): string {
  const value = rawValue.trim().startsWith("0x") ? rawValue.trim() : `0x${rawValue.trim()}`;
  if (!PRIVATE_KEY_RE.test(value)) {
    die(`${name} is not a valid 32-byte private key`);
  }
  return value;
}

function requireAddress(name: string, value: string): void {
  if (!ADDRESS_RE.test(value)) {
    die(`${name} is not a valid address: ${value}`);
  }
}

function asAddress(name: string, value: string): string {
  requireAddress(name, value);
  return value;
}

function readJson(filePath: string): any {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    die(`Failed to parse JSON file ${filePath}: ${msg}`);
  }
}

function jsonAddress(filePath: string, keys: string[]): string {
  const data = readJson(filePath);
  for (const key of keys) {
    const value = data[key];
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  die(`Failed to parse address from ${filePath}. Tried keys: ${keys.join(", ")}`);
}

function parseEnvFile(filePath: string): Record<string, string> {
  const out: Record<string, string> = {};
  const raw = readFileSync(filePath, "utf8");
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const idx = trimmed.indexOf("=");
    if (idx <= 0) {
      continue;
    }
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1);
    out[key] = value;
  }
  return out;
}

function writeEnvFile(filePath: string, env: Record<string, string>): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const lines = Object.entries(env).map(([k, v]) => `${k}=${v}`);
  writeFileSync(filePath, `${lines.join("\n")}\n`, "utf8");
}

function extractAddressFromOutput(label: string, output: string): string {
  const matches = output.match(/0x[a-fA-F0-9]{40}/g);
  if (!matches || matches.length === 0) {
    die(`Could not extract address for ${label} from output: ${output}`);
  }
  return matches[matches.length - 1];
}

function runOpDeployer(mountDir: string, image: string, args: string[]): void {
  mkdirSync(mountDir, { recursive: true });
  const uid = typeof process.getuid === "function" ? String(process.getuid()) : "1000";
  const gid = typeof process.getgid === "function" ? String(process.getgid()) : "1000";
  const result = run(
    "docker",
    [
      "run",
      "--rm",
      "-e",
      "HOME=/tmp",
      "-u",
      `${uid}:${gid}`,
      "-v",
      `${mountDir}:/work`,
      "-w",
      "/work",
      image,
      "op-deployer",
      ...args,
    ],
    { stdio: "inherit" },
  );
  if (result.status !== 0) {
    die(`op-deployer command failed: ${args.join(" ")}`);
  }
}

function waitForL2Rpc(rpcUrl: string): boolean {
  const attempts = 60;
  for (let i = 1; i <= attempts; i++) {
    const result = run("cast", ["chain-id", "--rpc-url", rpcUrl], { stdio: "pipe" });
    if (result.status === 0) {
      return true;
    }
    console.log(`Waiting for L2 RPC (${i}/${attempts})`);
    sleep(2000);
  }
  return false;
}

function contractHasCode(rpcUrl: string, address: string): boolean {
  const result = run("cast", ["code", address, "--rpc-url", rpcUrl], { stdio: "pipe" });
  if (result.status !== 0) {
    return false;
  }
  const code = (result.stdout ?? "").trim();
  return code.length > 0 && code !== "0x";
}

function waitForContractCode(rpcUrl: string, address: string, attempts: number): boolean {
  for (let i = 0; i < attempts; i++) {
    if (contractHasCode(rpcUrl, address)) {
      return true;
    }
    sleep(3000);
  }
  return false;
}

function clearRunJsonFiles(jsonDir: string, jsonFile: string): void {
  rmSync(jsonFile, { force: true });
  if (!existsSync(jsonDir)) {
    return;
  }
  for (const fileName of readdirSync(jsonDir)) {
    if (/^run-.*\.json$/.test(fileName)) {
      rmSync(path.join(jsonDir, fileName), { force: true });
    }
  }
}

function runForgeCreateWithRetry(
  timeoutBin: string,
  timeoutSeconds: number,
  maxAttempts: number,
  retrySleepSeconds: number,
  waitAttempts: number,
  description: string,
  rpcUrl: string,
  jsonFile: string,
  returnKey: string,
  cmd: string[],
): string {
  const jsonDir = path.dirname(jsonFile);
  mkdirSync(jsonDir, { recursive: true });

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    clearRunJsonFiles(jsonDir, jsonFile);

    const status = run(timeoutBin, [`${timeoutSeconds}s`, ...cmd], { stdio: "inherit" }).status;
    if (status !== 0) {
      if (status === 124) {
        log(`${description} attempt ${attempt}/${maxAttempts} timed out while waiting for receipts`);
      } else {
        log(`${description} attempt ${attempt}/${maxAttempts} failed with exit code ${String(status)}`);
      }
    }

    let parseFile = "";
    if (existsSync(jsonFile)) {
      parseFile = jsonFile;
    } else {
      const candidates = existsSync(jsonDir)
        ? readdirSync(jsonDir)
            .filter((f) => /^run-.*\.json$/.test(f))
            .sort()
            .map((f) => path.join(jsonDir, f))
        : [];
      if (candidates.length > 0) {
        parseFile = candidates[candidates.length - 1];
      }
    }

    let deployedAddress = "";
    if (parseFile) {
      const parsed = readJson(parseFile);
      const maybeValue = parsed?.returns?.[returnKey]?.value;
      if (typeof maybeValue === "string") {
        deployedAddress = maybeValue;
      }
      if (parseFile !== jsonFile && existsSync(parseFile)) {
        copyFileSync(parseFile, jsonFile);
      }
    }

    if (ADDRESS_RE.test(deployedAddress)) {
      if (waitForContractCode(rpcUrl, deployedAddress, waitAttempts)) {
        log(`${description} confirmed at ${deployedAddress}`);
        return deployedAddress;
      }
      log(`${description} returned ${deployedAddress} but code was not found yet`);
    }

    if (attempt < maxAttempts) {
      log(`Retrying ${description} in ${retrySleepSeconds}s`);
      sleep(retrySleepSeconds * 1000);
    }
  }

  die(`${description} failed after ${maxAttempts} attempts`);
}

function runForgeCallWithRetry(
  timeoutBin: string,
  timeoutSeconds: number,
  maxAttempts: number,
  retrySleepSeconds: number,
  description: string,
  verifyFn: () => boolean,
  cmd: string[],
): void {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const status = run(timeoutBin, [`${timeoutSeconds}s`, ...cmd], { stdio: "inherit" }).status;
    if (status !== 0) {
      if (status === 124) {
        log(`${description} attempt ${attempt}/${maxAttempts} timed out while waiting for receipts`);
      } else {
        log(`${description} attempt ${attempt}/${maxAttempts} failed with exit code ${String(status)}`);
      }
    }

    if (verifyFn()) {
      return;
    }

    if (attempt < maxAttempts) {
      log(`Retrying ${description} in ${retrySleepSeconds}s`);
      sleep(retrySleepSeconds * 1000);
    }
  }

  die(`${description} failed after ${maxAttempts} attempts`);
}

function ensureL2GasForDeployer(
  deployerAddress: string,
  deployerKey: string,
  rpcUrl: string,
  requiredWei: bigint,
): void {
  const deployerBalance = BigInt(runOrDie("cast", ["balance", deployerAddress, "--rpc-url", rpcUrl]));
  if (deployerBalance >= requiredWei) {
    log(`Deployer has sufficient L2 gas balance: ${deployerBalance.toString()} wei`);
    return;
  }

  const autoFund = (process.env.L2_AUTO_FUND_DEPLOYER ?? "true") === "true";
  if (!autoFund) {
    die(`Deployer L2 balance is too low (${deployerBalance.toString()} wei). Set L2_AUTO_FUND_DEPLOYER=true or pre-fund ${deployerAddress}`);
  }

  const faucetKey = normalizePrivateKey("L2_FAUCET_KEY", process.env.L2_FAUCET_KEY ?? DEFAULT_DEV_FUNDED_KEY);
  const faucetAddress = runOrDie("cast", ["wallet", "address", "--private-key", faucetKey]);
  const faucetBalance = BigInt(runOrDie("cast", ["balance", faucetAddress, "--rpc-url", rpcUrl]));
  if (faucetBalance < requiredWei) {
    die(`Faucet key has insufficient L2 balance (${faucetBalance.toString()} wei). Set L2_FAUCET_KEY to a funded key.`);
  }

  const configuredFundWei = process.env.L2_DEPLOYER_FUND_WEI ?? "1000000000000000000";
  const parsedFundWei = parseUIntString("L2_DEPLOYER_FUND_WEI", configuredFundWei);
  const fundWei = parsedFundWei < requiredWei ? requiredWei : parsedFundWei;

  log("Auto-funding deployer on L2 from faucet account");
  const sendResult = run(
    "cast",
    [
      "send",
      deployerAddress,
      "--value",
      fundWei.toString(),
      "--private-key",
      faucetKey,
      "--rpc-url",
      rpcUrl,
    ],
    { stdio: "inherit" },
  );
  if (sendResult.status !== 0) {
    die("Failed to auto-fund deployer on L2");
  }

  const updatedBalance = BigInt(runOrDie("cast", ["balance", deployerAddress, "--rpc-url", rpcUrl]));
  if (updatedBalance < requiredWei) {
    die(`Deployer L2 balance still insufficient after funding: ${updatedBalance.toString()} wei`);
  }
  log(`Deployer funded on L2: ${updatedBalance.toString()} wei`);

  // Keep this variable marked as used for parity with the shell deploy behavior.
  void deployerKey;
}

function validateOverrides(l1Rpc: string, disputeGameFactory: string, portalProxy: string): void {
  log("Validating fast override values for permissioned dispute game");
  const permissionedImpl = asAddress(
    "PERMISSIONED_IMPL",
    runOrDie("cast", ["call", disputeGameFactory, "gameImpls(uint32)(address)", "1", "--rpc-url", l1Rpc]),
  );
  const maxClock = runOrDie("cast", ["call", permissionedImpl, "maxClockDuration()(uint64)", "--rpc-url", l1Rpc]);
  const clockExt = runOrDie("cast", ["call", permissionedImpl, "clockExtension()(uint64)", "--rpc-url", l1Rpc]);
  const proofDelay = runOrDie("cast", ["call", portalProxy, "proofMaturityDelaySeconds()(uint256)", "--rpc-url", l1Rpc]);
  const finalityDelay = runOrDie("cast", ["call", portalProxy, "disputeGameFinalityDelaySeconds()(uint256)", "--rpc-url", l1Rpc]);

  if (maxClock !== "15") {
    die(`Unexpected maxClockDuration: ${maxClock}`);
  }
  if (clockExt !== "5") {
    die(`Unexpected clockExtension: ${clockExt}`);
  }
  if (proofDelay !== "15") {
    die(`Unexpected proofMaturityDelaySeconds: ${proofDelay}`);
  }
  if (finalityDelay !== "1") {
    die(`Unexpected disputeGameFinalityDelaySeconds: ${finalityDelay}`);
  }
}

function ensureComposeIsUp(devnetDir: string): void {
  const upResult = run("docker", ["compose", "up", "-d"], { cwd: devnetDir, stdio: "inherit" });
  if (upResult.status !== 0) {
    die("Failed to start docker compose services");
  }
  const psResult = run("docker", ["compose", "ps"], { cwd: devnetDir, stdio: "inherit" });
  if (psResult.status !== 0) {
    die("Failed to read docker compose service status");
  }
}

function ensureChainReadyAndValidated(
  l2RpcUrl: string,
  expectedChainId: string,
  l1Rpc: string,
  disputeGameFactory: string,
  portalProxy: string,
  deployerAddress: string,
  deployerKey: string,
  minWei: bigint,
): void {
  if (!waitForL2Rpc(l2RpcUrl)) {
    die(`L2 RPC did not come up on ${l2RpcUrl}`);
  }

  const chainId = runOrDie("cast", ["chain-id", "--rpc-url", l2RpcUrl]);
  if (chainId !== expectedChainId) {
    die(`Unexpected L2 chain id. expected=${expectedChainId} got=${chainId}`);
  }

  const isCgt = runOrDie("cast", [
    "call",
    IS_CUSTOM_GAS_TOKEN_PREDEPLOY,
    "isCustomGasToken()(bool)",
    "--rpc-url",
    l2RpcUrl,
  ]);
  if (isCgt !== "true") {
    die(`isCustomGasToken returned ${isCgt}`);
  }

  ensureL2GasForDeployer(deployerAddress, deployerKey, l2RpcUrl, minWei);
  validateOverrides(l1Rpc, disputeGameFactory, portalProxy);
}

function writeLatestEnvFile(context: DeployContext, runId: string, extras: Record<string, string> = {}): void {
  const env: Record<string, string> = {
    RUN_ID: runId,
    WORKDIR: context.chainDir,
    SUPERCHAIN_DIR: context.superchainDir,
    IMPLEMENTATIONS_DIR: context.implementationsDir,
    L2_CHAIN_ID: context.chainIdDec,
    DISPUTE_GAME_FACTORY: context.disputeGameFactory,
    PORTAL_ADDRESS: context.portalProxy,
    L1_MESSENGER: context.l1Messenger,
    L2_RPC: context.l2RpcUrl,
    ...extras,
  };
  writeEnvFile(E2E_LATEST_ENV, env);
}

function loadChainContextFromLatestEnv(l2RpcUrl: string): { context: DeployContext; runId: string } {
  if (!existsSync(E2E_LATEST_ENV)) {
    die(`Missing ${E2E_LATEST_ENV}. Run deploy-chain first.`);
  }

  const env = parseEnvFile(E2E_LATEST_ENV);
  const chainDir = env.WORKDIR;
  if (!chainDir) {
    die(`WORKDIR missing from ${E2E_LATEST_ENV}. Run deploy-chain first.`);
  }
  const stateFile = path.join(chainDir, "state.json");
  if (!existsSync(stateFile)) {
    die(`Missing ${stateFile}. Run deploy-chain first.`);
  }

  const state = readJson(stateFile);
  const chainIdHex = String(state?.appliedIntent?.chains?.[0]?.id ?? "");
  if (!chainIdHex.startsWith("0x")) {
    die(`Invalid chain id in ${stateFile}: ${chainIdHex}`);
  }

  const context: DeployContext = {
    chainDir,
    superchainDir: env.SUPERCHAIN_DIR ?? "",
    implementationsDir: env.IMPLEMENTATIONS_DIR ?? "",
    chainIdDec: BigInt(chainIdHex).toString(),
    disputeGameFactory: asAddress(
      "DISPUTE_GAME_FACTORY",
      String(state?.opChainDeployments?.[0]?.DisputeGameFactoryProxy ?? ""),
    ),
    portalProxy: asAddress(
      "PORTAL_PROXY",
      String(state?.opChainDeployments?.[0]?.OptimismPortalProxy ?? ""),
    ),
    l1Messenger: asAddress(
      "L1_MESSENGER",
      String(state?.opChainDeployments?.[0]?.L1CrossDomainMessengerProxy ?? ""),
    ),
    l2RpcUrl,
  };

  return {
    context,
    runId: env.RUN_ID ?? nowRunId(),
  };
}

function deployChainPhase(
  runId: string,
  workRoot: string,
  l2ChainIdDec: string,
  opDeployerImage: string,
  opRethImage: string,
  l1Rpc: string,
  l1Beacon: string,
  deployerKey: string,
  sequencerKey: string,
  batcherKey: string,
  proposerKey: string,
  deployerAddress: string,
  sequencerAddress: string,
  batcherAddress: string,
  proposerAddress: string,
  superchainProxyAdminOwner: string,
  protocolVersionsOwner: string,
  guardianAddress: string,
  l1ProxyAdminOwner: string,
  challengerAddress: string,
  l2HttpPort: string,
  l2WsPort: string,
  l2AuthPort: string,
  opNodeRpcPort: string,
  minWei: bigint,
): DeployContext {
  const l2ChainIdHex = `0x${BigInt(l2ChainIdDec).toString(16).padStart(64, "0")}`;
  const superchainDir = path.join(workRoot, `superchain-${runId}`);
  const implDir = path.join(workRoot, `implementations-${runId}`);
  const chainDir = path.join(workRoot, `netnew-${runId}`);
  mkdirSync(superchainDir, { recursive: true });
  mkdirSync(implDir, { recursive: true });
  mkdirSync(chainDir, { recursive: true });

  log("Stopping existing docker compose services");
  run(
    "docker",
    [
      "compose",
      "-f",
      path.join(DEVNET_DIR, "docker-compose.yml"),
      "-p",
      "cgt-devnet",
      "down",
      "--remove-orphans",
      "-v",
    ],
    { stdio: "inherit" },
  );

  log("Bootstrapping new superchain singletons");
  runOpDeployer(superchainDir, opDeployerImage, [
    "bootstrap",
    "superchain",
    "--l1-rpc-url",
    l1Rpc,
    "--private-key",
    deployerKey,
    "--superchain-proxy-admin-owner",
    superchainProxyAdminOwner,
    "--protocol-versions-owner",
    protocolVersionsOwner,
    "--guardian",
    guardianAddress,
    "--outfile",
    "/work/bootstrap-superchain.json",
  ]);

  const bootstrapSuperchainFile = path.join(superchainDir, "bootstrap-superchain.json");
  const superchainConfigProxy = asAddress(
    "SUPERCHAIN_CONFIG_PROXY",
    jsonAddress(bootstrapSuperchainFile, [
      "superchainConfigProxyAddress",
      "superchainConfigProxy",
      "SuperchainConfigProxy",
    ]),
  );
  const protocolVersionsProxy = asAddress(
    "PROTOCOL_VERSIONS_PROXY",
    jsonAddress(bootstrapSuperchainFile, [
      "protocolVersionsProxyAddress",
      "protocolVersionsProxy",
      "ProtocolVersionsProxy",
    ]),
  );
  const superchainProxyAdmin = asAddress(
    "SUPERCHAIN_PROXY_ADMIN",
    jsonAddress(bootstrapSuperchainFile, ["proxyAdminAddress", "ProxyAdmin", "superchainProxyAdmin"]),
  );

  log("Bootstrapping fast implementations and OPCM");
  runOpDeployer(implDir, opDeployerImage, [
    "bootstrap",
    "implementations",
    "--l1-rpc-url",
    l1Rpc,
    "--private-key",
    deployerKey,
    "--superchain-config-proxy",
    superchainConfigProxy,
    "--protocol-versions-proxy",
    protocolVersionsProxy,
    "--superchain-proxy-admin",
    superchainProxyAdmin,
    "--l1-proxy-admin-owner",
    l1ProxyAdminOwner,
    "--challenger",
    challengerAddress,
    "--challenge-period-seconds",
    "5",
    "--proof-maturity-delay-seconds",
    "15",
    "--dispute-game-finality-delay-seconds",
    "1",
    "--dispute-clock-extension",
    "5",
    "--dispute-max-clock-duration",
    "15",
    "--outfile",
    "/work/bootstrap-implementations.json",
  ]);

  const opcmAddress = asAddress(
    "OPCM_ADDRESS",
    jsonAddress(path.join(implDir, "bootstrap-implementations.json"), ["opcmAddress"]),
  );

  log("Initializing custom intent for net-new chain");
  runOpDeployer(chainDir, opDeployerImage, [
    "init",
    "--workdir",
    "/work",
    "--intent-type",
    "custom",
    "--l1-chain-id",
    "11155111",
    "--l2-chain-ids",
    l2ChainIdDec,
  ]);

  const intentTemplate = path.join(DEVNET_DIR, "intent.toml.example");
  const intentPath = path.join(chainDir, "intent.toml");
  let intentContent = readFileSync(intentTemplate, "utf8");
  intentContent = intentContent
    .split("0xYOUR_BOOTSTRAPPED_OPCM_ADDRESS")
    .join(opcmAddress)
    .split("0x00000000000000000000000000000000000000000000000000000000deadbeef")
    .join(l2ChainIdHex)
    .split("0xYOUR_ADDRESS")
    .join(deployerAddress)
    .split("0xYOUR_SEQUENCER_ADDRESS")
    .join(sequencerAddress)
    .split("0xYOUR_BATCHER_ADDRESS")
    .join(batcherAddress)
    .split("0xYOUR_PROPOSER_ADDRESS")
    .join(proposerAddress);
  writeFileSync(intentPath, intentContent, "utf8");

  log("Applying intent (deploying L1 contracts)");
  runOpDeployer(chainDir, opDeployerImage, [
    "apply",
    "--workdir",
    "/work",
    "--l1-rpc-url",
    l1Rpc,
    "--private-key",
    deployerKey,
  ]);

  const stateFile = path.join(chainDir, "state.json");
  const state = readJson(stateFile);
  const chainIdHex = String(state?.appliedIntent?.chains?.[0]?.id ?? "");
  if (!chainIdHex.startsWith("0x")) {
    die(`Invalid chain id in ${stateFile}: ${chainIdHex}`);
  }
  const chainIdDec = BigInt(chainIdHex).toString();
  const disputeGameFactory = asAddress(
    "DISPUTE_GAME_FACTORY",
    String(state?.opChainDeployments?.[0]?.DisputeGameFactoryProxy ?? ""),
  );
  const portalProxy = asAddress(
    "PORTAL_PROXY",
    String(state?.opChainDeployments?.[0]?.OptimismPortalProxy ?? ""),
  );
  const l1Messenger = asAddress(
    "L1_MESSENGER",
    String(state?.opChainDeployments?.[0]?.L1CrossDomainMessengerProxy ?? ""),
  );

  log("Generating deploy-config/genesis/rollup artifacts");
  runOpDeployer(chainDir, opDeployerImage, [
    "inspect",
    "deploy-config",
    "--workdir",
    "/work",
    "--outfile",
    "/work/deploy-config.json",
    chainIdDec,
  ]);

  runOpDeployer(chainDir, opDeployerImage, [
    "inspect",
    "genesis",
    "--workdir",
    "/work",
    "--outfile",
    "/work/genesis.json",
    chainIdDec,
  ]);

  runOpDeployer(chainDir, opDeployerImage, [
    "inspect",
    "rollup",
    "--workdir",
    "/work",
    "--outfile",
    "/work/rollup.json",
    chainIdDec,
  ]);

  const deployConfig = readJson(path.join(chainDir, "deploy-config.json"));
  if (String(deployConfig?.useCustomGasToken) !== "true") {
    die(`Deploy config useCustomGasToken is not true: ${String(deployConfig?.useCustomGasToken)}`);
  }
  const rollupConfig = readJson(path.join(chainDir, "rollup.json"));
  const batchInbox = String(rollupConfig?.batch_inbox_address ?? "");
  requireAddress("BATCH_INBOX", batchInbox);

  copyFileSync(path.join(chainDir, "genesis.json"), path.join(DEVNET_DIR, "genesis.json"));
  copyFileSync(path.join(chainDir, "rollup.json"), path.join(DEVNET_DIR, "rollup.json"));
  writeFileSync(path.join(DEVNET_DIR, "jwt.hex"), `${randomBytes(32).toString("hex")}\n`, "utf8");
  writeFileSync(path.join(DEVNET_DIR, "p2p-key.txt"), `${randomBytes(32).toString("hex")}\n`, "utf8");

  log("Writing devnet/.env");
  writeEnvFile(path.join(DEVNET_DIR, ".env"), {
    L1_RPC: l1Rpc,
    L1_BEACON: l1Beacon,
    SEQUENCER_KEY: sequencerKey,
    BATCHER_KEY: batcherKey,
    PROPOSER_KEY: proposerKey,
    L2_CHAIN_ID: chainIdDec,
    DISPUTE_GAME_FACTORY: disputeGameFactory,
    BATCH_INBOX: batchInbox,
    OP_RETH_IMAGE: opRethImage,
    GENESIS_FILE: "./genesis.json",
    ROLLUP_FILE: "./rollup.json",
    JWT_FILE: "./jwt.hex",
    P2P_KEY_FILE: "./p2p-key.txt",
    L2_HTTP_PORT: l2HttpPort,
    L2_WS_PORT: l2WsPort,
    L2_AUTH_PORT: l2AuthPort,
    OP_NODE_RPC_PORT: opNodeRpcPort,
  });

  log("Starting docker compose services");
  ensureComposeIsUp(DEVNET_DIR);

  const context: DeployContext = {
    chainDir,
    superchainDir,
    implementationsDir: implDir,
    chainIdDec,
    disputeGameFactory,
    portalProxy,
    l1Messenger,
    l2RpcUrl: `http://127.0.0.1:${l2HttpPort}`,
  };

  ensureChainReadyAndValidated(
    context.l2RpcUrl,
    context.chainIdDec,
    l1Rpc,
    context.disputeGameFactory,
    context.portalProxy,
    deployerAddress,
    deployerKey,
    minWei,
  );

  writeLatestEnvFile(context, runId);
  return context;
}

function deployBridgePhase(
  context: DeployContext,
  runId: string,
  timeoutBin: string,
  timeoutSeconds: number,
  maxAttempts: number,
  retrySleepSeconds: number,
  waitAttempts: number,
  l1Rpc: string,
  deployerKey: string,
  deployerKeyHex: string,
  deployerAddress: string,
  tokenName: string,
  tokenSymbol: string,
  tokenDecimals: number,
  tokenInitialSupplyRaw: string,
): void {
  log("Deploying devnet ERC-20 token on L1");
  const l1TokenBroadcastJson = path.join(
    ROOT_DIR,
    "broadcast",
    "DeployDevnetMintableToken.s.sol",
    "11155111",
    "run-latest.json",
  );
  const l1Token = asAddress(
    "L1_TOKEN",
    runForgeCreateWithRetry(
      timeoutBin,
      timeoutSeconds,
      maxAttempts,
      retrySleepSeconds,
      waitAttempts,
      "L1 token deployment",
      l1Rpc,
      l1TokenBroadcastJson,
      "token_",
      [
        "forge",
        "script",
        "script/DeployDevnetMintableToken.s.sol:DeployDevnetMintableToken",
        "--sig",
        "run(string,string,uint8,address,uint256)",
        tokenName,
        tokenSymbol,
        String(tokenDecimals),
        deployerAddress,
        tokenInitialSupplyRaw,
        "--rpc-url",
        l1Rpc,
        "--private-key",
        deployerKey,
        "--broadcast",
      ],
    ),
  );

  log("Deploying bridge contracts (L1 then L2)");
  const l2Nonce = runOrDie("cast", ["nonce", deployerAddress, "--rpc-url", context.l2RpcUrl]);
  const computedAddrOut = runOrDie("cast", ["compute-address", deployerAddress, "--nonce", l2Nonce]);
  const l2BridgePredicted = asAddress(
    "L2_BRIDGE_PREDICTED",
    extractAddressFromOutput("L2_BRIDGE_PREDICTED", computedAddrOut),
  );

  const l1BridgeBroadcastJson = path.join(
    ROOT_DIR,
    "broadcast",
    "DeployCGTBridge.s.sol",
    "11155111",
    "run-latest.json",
  );
  const l1Bridge = asAddress(
    "L1_BRIDGE",
    runForgeCreateWithRetry(
      timeoutBin,
      timeoutSeconds,
      maxAttempts,
      retrySleepSeconds,
      waitAttempts,
      "L1 bridge deployment",
      l1Rpc,
      l1BridgeBroadcastJson,
      "bridge_",
      [
        "forge",
        "script",
        "script/DeployCGTBridge.s.sol:DeployCGTBridgeL1",
        "--sig",
        "run(address,uint8,address,address)",
        l1Token,
        String(tokenDecimals),
        l2BridgePredicted,
        context.l1Messenger,
        "--rpc-url",
        l1Rpc,
        "--private-key",
        deployerKey,
        "--broadcast",
      ],
    ),
  );

  const l2BridgeBroadcastJson = path.join(
    ROOT_DIR,
    "broadcast",
    "DeployCGTBridge.s.sol",
    context.chainIdDec,
    "run-latest.json",
  );
  const l2Bridge = asAddress(
    "L2_BRIDGE",
    runForgeCreateWithRetry(
      timeoutBin,
      timeoutSeconds,
      maxAttempts,
      retrySleepSeconds,
      waitAttempts,
      "L2 bridge deployment",
      context.l2RpcUrl,
      l2BridgeBroadcastJson,
      "bridge_",
      [
        "forge",
        "script",
        "script/DeployCGTBridge.s.sol:DeployCGTBridgeL2",
        "--sig",
        "run(address,address,uint8,address)",
        l1Bridge,
        L2_MESSENGER_PREDEPLOY,
        String(tokenDecimals),
        LIQUIDITY_CONTROLLER_PREDEPLOY,
        "--rpc-url",
        context.l2RpcUrl,
        "--private-key",
        deployerKey,
        "--broadcast",
      ],
    ),
  );

  if (l2Bridge.toLowerCase() !== l2BridgePredicted.toLowerCase()) {
    die(`L2 bridge address mismatch. predicted=${l2BridgePredicted} actual=${l2Bridge}`);
  }

  log("Authorizing L2 bridge as LiquidityController minter");
  runForgeCallWithRetry(
    timeoutBin,
    timeoutSeconds,
    maxAttempts,
    retrySleepSeconds,
    "L2 bridge minter authorization",
    () => {
      const val = runOrDie("cast", [
        "call",
        LIQUIDITY_CONTROLLER_PREDEPLOY,
        "minters(address)(bool)",
        l2Bridge,
        "--rpc-url",
        context.l2RpcUrl,
      ]);
      return val === "true";
    },
    [
      "forge",
      "script",
      "script/DeployCGTBridge.s.sol:DeployCGTBridgeL2",
      "--sig",
      "authorizeMinter(address,address)",
      LIQUIDITY_CONTROLLER_PREDEPLOY,
      l2Bridge,
      "--rpc-url",
      context.l2RpcUrl,
      "--private-key",
      deployerKey,
      "--broadcast",
    ],
  );

  const isMinter = runOrDie("cast", [
    "call",
    LIQUIDITY_CONTROLLER_PREDEPLOY,
    "minters(address)(bool)",
    l2Bridge,
    "--rpc-url",
    context.l2RpcUrl,
  ]);
  if (isMinter !== "true") {
    die("L2 bridge was not authorized as minter");
  }

  log("Writing tasks/.env.runtime and devnet/work/e2e-latest.env");
  writeEnvFile(path.join(ROOT_DIR, "tasks", ".env.runtime"), {
    L1_RPC: l1Rpc,
    L2_RPC: context.l2RpcUrl,
    PRIVATE_KEY: deployerKeyHex,
    L2_CHAIN_ID: context.chainIdDec,
    L1_BRIDGE: l1Bridge,
    L2_BRIDGE: l2Bridge,
    L1_TOKEN: l1Token,
    TOKEN_DECIMALS: String(tokenDecimals),
    DISPUTE_GAME_FACTORY: context.disputeGameFactory,
    PORTAL_ADDRESS: context.portalProxy,
  });

  writeLatestEnvFile(context, runId, {
    L1_BRIDGE: l1Bridge,
    L2_BRIDGE: l2Bridge,
    L1_TOKEN: l1Token,
    TOKEN_DECIMALS: String(tokenDecimals),
  });
}

function ensureNodeDepsInstalled(): void {
  const nodeModulesDir = path.join(ROOT_DIR, "tasks", "node_modules");
  if (existsSync(nodeModulesDir)) {
    return;
  }
  log("Installing Node dependencies in tasks/");
  const packageLockPath = path.join(ROOT_DIR, "tasks", "package-lock.json");
  const command = existsSync(packageLockPath) ? ["ci", "--no-audit", "--no-fund"] : ["install", "--no-audit", "--no-fund"];
  const result = run("npm", command, { cwd: path.join(ROOT_DIR, "tasks"), stdio: "inherit" });
  if (result.status !== 0) {
    die("Failed to install Node dependencies for tasks/");
  }
}

function main(): void {
  process.chdir(ROOT_DIR);

  const phaseArg = process.argv[2] ?? process.env.DEPLOY_PHASE ?? "all";
  if (phaseArg !== "chain" && phaseArg !== "bridge" && phaseArg !== "all") {
    die("Deploy phase must be one of: chain, bridge, all");
  }
  const phase = phaseArg as DeployPhase;

  requireCmd("docker");
  requireCmd("cast");
  requireCmd("forge");
  requireCmd("npm");
  requireDockerComposePlugin();

  const timeoutBin = commandExists("timeout") ? "timeout" : commandExists("gtimeout") ? "gtimeout" : "";
  if (!timeoutBin) {
    die("Missing required command: timeout (or gtimeout on macOS)");
  }

  ensureNodeDepsInstalled();

  const l1Rpc = requireEnv("L1_RPC");
  const l1Beacon = requireEnv("L1_BEACON");
  const deployerKey = normalizePrivateKey("DEPLOYER_KEY", requireEnv("DEPLOYER_KEY"));
  const sequencerKey = normalizePrivateKey("SEQUENCER_KEY", requireEnv("SEQUENCER_KEY"));
  const batcherKey = normalizePrivateKey("BATCHER_KEY", requireEnv("BATCHER_KEY"));
  const proposerKey = normalizePrivateKey("PROPOSER_KEY", requireEnv("PROPOSER_KEY"));

  const opDeployerImage = process.env.OP_DEPLOYER_IMAGE ?? "us-docker.pkg.dev/oplabs-tools-artifacts/images/op-deployer:v0.6.0-rc.2";
  const opRethImage = process.env.OP_RETH_IMAGE ?? "us-docker.pkg.dev/oplabs-tools-artifacts/images/op-reth:v1.10.0";
  const workRoot = process.env.WORK_ROOT ?? WORK_ROOT_DEFAULT;
  let runId = process.env.RUN_ID ?? nowRunId();

  const l2HttpPort = process.env.L2_HTTP_PORT ?? "19545";
  const l2WsPort = process.env.L2_WS_PORT ?? "19546";
  const l2AuthPort = process.env.L2_AUTH_PORT ?? "19551";
  const opNodeRpcPort = process.env.OP_NODE_RPC_PORT ?? "17000";

  const timeoutSeconds = Number(parseUIntString("FORGE_BROADCAST_TIMEOUT_SECONDS", process.env.FORGE_BROADCAST_TIMEOUT_SECONDS ?? "180"));
  const maxAttempts = Number(parseUIntString("FORGE_BROADCAST_MAX_ATTEMPTS", process.env.FORGE_BROADCAST_MAX_ATTEMPTS ?? "3"));
  const retrySleepSeconds = Number(parseUIntString("FORGE_RETRY_SLEEP_SECONDS", process.env.FORGE_RETRY_SLEEP_SECONDS ?? "8"));
  const waitAttempts = Number(parseUIntString("FORGE_CONTRACT_WAIT_ATTEMPTS", process.env.FORGE_CONTRACT_WAIT_ATTEMPTS ?? "20"));

  const tokenName = process.env.TOKEN_NAME ?? "Devnet USD";
  const tokenSymbol = process.env.TOKEN_SYMBOL ?? "dUSD";
  const tokenDecimals = Number(parseUIntString("TOKEN_DECIMALS", process.env.TOKEN_DECIMALS ?? "6"));
  const tokenInitialSupplyTokens = parseUIntString(
    "TOKEN_INITIAL_SUPPLY_TOKENS",
    process.env.TOKEN_INITIAL_SUPPLY_TOKENS ?? "10000000",
  ).toString();
  const tokenInitialSupplyRaw = `${tokenInitialSupplyTokens}${"0".repeat(tokenDecimals)}`;

  const deployerAddress = asAddress(
    "DEPLOYER_ADDRESS",
    runOrDie("cast", ["wallet", "address", "--private-key", deployerKey]),
  );
  const deployerKeyHex = deployerKey;
  const sequencerAddress = asAddress(
    "SEQUENCER_ADDRESS",
    runOrDie("cast", ["wallet", "address", "--private-key", sequencerKey]),
  );
  const batcherAddress = asAddress(
    "BATCHER_ADDRESS",
    runOrDie("cast", ["wallet", "address", "--private-key", batcherKey]),
  );
  const proposerAddress = asAddress(
    "PROPOSER_ADDRESS",
    runOrDie("cast", ["wallet", "address", "--private-key", proposerKey]),
  );

  const superchainProxyAdminOwner = asAddress(
    "SUPERCHAIN_PROXY_ADMIN_OWNER",
    process.env.SUPERCHAIN_PROXY_ADMIN_OWNER ?? deployerAddress,
  );
  const protocolVersionsOwner = asAddress(
    "PROTOCOL_VERSIONS_OWNER",
    process.env.PROTOCOL_VERSIONS_OWNER ?? deployerAddress,
  );
  const guardianAddress = asAddress("GUARDIAN_ADDRESS", process.env.GUARDIAN_ADDRESS ?? deployerAddress);
  const l1ProxyAdminOwner = asAddress("L1_PROXY_ADMIN_OWNER", process.env.L1_PROXY_ADMIN_OWNER ?? deployerAddress);
  const challengerAddress = asAddress("CHALLENGER_ADDRESS", process.env.CHALLENGER_ADDRESS ?? deployerAddress);

  const l2ChainIdDec = process.env.L2_CHAIN_ID_DEC
    ? parseUIntString("L2_CHAIN_ID_DEC", process.env.L2_CHAIN_ID_DEC).toString()
    : (300000000000000n + BigInt(Math.floor(Date.now() / 1000)) + BigInt(Math.floor(Math.random() * 65536))).toString();

  const minWei = parseUIntString("L2_DEPLOYER_MIN_WEI", process.env.L2_DEPLOYER_MIN_WEI ?? "200000000000000000");

  let context: DeployContext;

  if (phase === "chain" || phase === "all") {
    context = deployChainPhase(
      runId,
      workRoot,
      l2ChainIdDec,
      opDeployerImage,
      opRethImage,
      l1Rpc,
      l1Beacon,
      deployerKey,
      sequencerKey,
      batcherKey,
      proposerKey,
      deployerAddress,
      sequencerAddress,
      batcherAddress,
      proposerAddress,
      superchainProxyAdminOwner,
      protocolVersionsOwner,
      guardianAddress,
      l1ProxyAdminOwner,
      challengerAddress,
      l2HttpPort,
      l2WsPort,
      l2AuthPort,
      opNodeRpcPort,
      minWei,
    );
  } else {
    const loaded = loadChainContextFromLatestEnv(`http://127.0.0.1:${l2HttpPort}`);
    runId = loaded.runId;
    context = loaded.context;
    log("Ensuring docker compose services are running");
    ensureComposeIsUp(DEVNET_DIR);
    ensureChainReadyAndValidated(
      context.l2RpcUrl,
      context.chainIdDec,
      l1Rpc,
      context.disputeGameFactory,
      context.portalProxy,
      deployerAddress,
      deployerKey,
      minWei,
    );
  }

  if (phase === "chain") {
    log("Chain deployment complete");
    console.log("Next step: just deploy-bridge");
    return;
  }

  deployBridgePhase(
    context,
    runId,
    timeoutBin,
    timeoutSeconds,
    maxAttempts,
    retrySleepSeconds,
    waitAttempts,
    l1Rpc,
    deployerKey,
    deployerKeyHex,
    deployerAddress,
    tokenName,
    tokenSymbol,
    tokenDecimals,
    tokenInitialSupplyRaw,
  );

  if (phase === "bridge") {
    log("Bridge deployment complete");
  } else {
    log("Deployment complete");
  }
  console.log("Run deposit test:   just deposit-test 1");
  console.log("Run withdrawal test: just withdraw-test 1");
}

main();
