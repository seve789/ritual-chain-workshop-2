/**
 * Full local demo of the self-resolving prediction market on a Hardhat node —
 * the Ritual chain is down, so this is how you watch the whole lifecycle:
 * the Scheduler wakes the contract, the mocked HTTP/jq precompiles answer, and
 * the market settles itself. No real chain, no real funds, no resolve button.
 *
 *   Terminal 1:  npx hardhat node
 *   Terminal 2:  npx hardhat run scripts/local-demo.ts
 *
 * The node needs zero configuration: this script etches the mock system
 * contracts / precompiles at their canonical Ritual addresses via
 * hardhat_setCode, then drives the exact workshop flow.
 */
import { network } from "hardhat";
import { formatEther, parseEther } from "viem";

import { RITUAL, RITUAL_WALLET_ABI } from "./ritual.ts";
import { MARKET_STATE, OUTCOME } from "./market-presets.ts";

const BLOCK_TIME_MS = BigInt(process.env.BLOCK_TIME_MS ?? 200); // 5 blocks/s
const BETTING_SECONDS = BigInt(process.env.BETTING_SECONDS ?? 30); // 150 blocks
const DELAY_SECONDS = BigInt(process.env.RESOLVE_DELAY_SECONDS ?? 15); // 75 blocks

const EXECUTOR = "0x000000000000000000000000000000000000007E";

const connection = await network.create({ network: "localRitual", chainType: "l1" });
const publicClient = await connection.viem.getPublicClient();
const [deployer, alice] = await connection.viem.getWalletClients();

const rpc = (method: string, params: unknown[]) =>
  publicClient.request({ method, params } as never);

const MOCK_AT: Record<string, `0x${string}`> = {
  MockScheduler: RITUAL.scheduler,
  MockRitualWallet: RITUAL.ritualWallet,
  MockTEEServiceRegistry: RITUAL.teeServiceRegistry,
  MockHTTPPrecompile: RITUAL.httpPrecompile,
  MockJQPrecompile: RITUAL.jqPrecompile,
};

async function etchMocks() {
  for (const name of Object.keys(MOCK_AT) as Array<keyof typeof MOCK_AT>) {
    const address = MOCK_AT[name];
    // Deploy the mock normally, then copy its RUNTIME code to the canonical
    // address. Artifact .bytecode is creation code — setCode needs deployed
    // code, and getCode() returns exactly that.
    const mock = await connection.viem.deployContract(name);
    const runtimeCode = (await publicClient.getCode({ address: mock.address }))!;
    await rpc("hardhat_setCode", [address, runtimeCode]);
    console.log(`  mock ${name.padEnd(22)} → ${address}`);
  }
}

async function mineTo(target: bigint | number) {
  const current = await publicClient.getBlockNumber();
  const targetBig = BigInt(target);
  if (current >= targetBig) return;
  console.log(`  mining ${targetBig - current} blocks…`);
  for (let b = current; b < targetBig; b++) await rpc("evm_mine", []);
}

const line = (label: string, value: string) =>
  console.log(`  ${label.padEnd(28)} ${value}`);

console.log("── RitualPredict local demo ──────────────────────────────");
console.log(`Deployer: ${deployer.account.address}`);
console.log(`Oracle:   ETH/USD via mocked HTTP 0x0801 → jq 0x0803`);

console.log("");
console.log("── Etch mocks at canonical Ritual addresses ──────────────");
await etchMocks();

console.log("");
console.log("── Deploy + prepay execution fees ────────────────────────");
const predict = await connection.viem.deployContract("RitualPredict", [BLOCK_TIME_MS]);
line("RitualPredict", predict.address);

await predict.write.fundExecution([500000n], { value: parseEther("0.5") });
const [balance, lockUntil] = await Promise.all([
  predict.read.executionBalance(),
  publicClient.readContract({
    address: RITUAL.ritualWallet,
    abi: RITUAL_WALLET_ABI,
    functionName: "lockUntil",
    args: [predict.address],
  }),
]);
line("execution balance", `${formatEther(balance)} RITUAL (locked to block ${lockUntil})`);

// Point the mocked precompiles at a bullish ETH price.
const http = await connection.viem.getContractAt("MockHTTPPrecompile", RITUAL.httpPrecompile);
const jq = await connection.viem.getContractAt("MockJQPrecompile", RITUAL.jqPrecompile);
const registry = await connection.viem.getContractAt("MockTEEServiceRegistry", RITUAL.teeServiceRegistry);
await http.write.setResponse([200, "0x7b227072696365223a20343230307d", ""]); // {"price": 4200}
await jq.write.setResult([4200n, true]);
await registry.write.setExecutor([EXECUTOR, true]);

console.log("");
console.log("── Create the market ─────────────────────────────────────");
const createHash = await predict.write.createMarket([
  {
    question: "Will ETH/USD be at least $4,000 when this market resolves?",
    oracleUrl: "https://oracle.example/eth",
    jsonPath: ".price",
    target: 4000n,
    comparator: 1, // GTE
    bettingSeconds: BETTING_SECONDS,
    resolveDelaySeconds: DELAY_SECONDS,
  },
]);
await publicClient.waitForTransactionReceipt({ hash: createHash });

const created = await predict.read.getMarket([1n]);
line("market #1", created.question);
line("rule", `observed ≥ 4000 (jq ${created.jsonPath})`);
line("betting closes", `block ${created.closeBlock}`);
line("scheduler fires", `block ${created.resolveBlock} (schedule ${created.scheduleId})`);

console.log("");
console.log("── Bets ──────────────────────────────────────────────────");
await predict.write.bet([1n, true], { value: parseEther("1.5") }); // deployer: YES
await predict.write.bet([1n, false], { value: parseEther("1"), account: alice.account }); // alice: NO
line("YES", `1.5 RITUAL (${deployer.account.address})`);
line("NO", `1.0 RITUAL (${alice.account.address})`);

console.log("");
console.log("── Betting window closes ─────────────────────────────────");
await mineTo(created.closeBlock);
const closed = await predict.read.getMarket([1n]);
line("state", MARKET_STATE[closed.state]);

console.log("");
console.log("── The Scheduler wakes the contract (nobody presses a button) ──");
await mineTo(created.resolveBlock);
// Impersonate the Scheduler so its callback can be fired; fund it for gas
// (impersonated accounts need a balance or the RPC rejects the tx).
await rpc("hardhat_impersonateAccount", [RITUAL.scheduler]);
await rpc("hardhat_setBalance", [RITUAL.scheduler, "0xDE0B6B3A7640000"]); // 1 ETH
const schedulerWallet = await connection.viem.getWalletClient(RITUAL.scheduler);
const resolveHash = await schedulerWallet.writeContract({
  address: predict.address,
  abi: predict.abi,
  functionName: "onScheduledResolve",
  args: [0n, 1n],
});
await publicClient.waitForTransactionReceipt({ hash: resolveHash });

const resolved = await predict.read.getMarket([1n]);
line("state", MARKET_STATE[resolved.state]);
line("outcome", OUTCOME[resolved.outcome]);
line("observed", `$${resolved.observedValue}`);
line("attempts", `${resolved.attempts}/3 (schedule cancelled)`);

console.log("");
console.log("── Winners claim ─────────────────────────────────────────");
const deployerBefore = await publicClient.getBalance({ address: deployer.account.address });
await predict.write.claimWinnings([1n]); // deployer bet YES and won
const deployerAfter = await publicClient.getBalance({ address: deployer.account.address });
line("deployer (YES, winner)", `+${formatEther(deployerAfter - deployerBefore)} RITUAL`);

// alice backed the losing side — the claim reverts with NothingToClaim.
try {
  await predict.write.claimWinnings([1n], { account: alice.account });
  line("alice (NO, losing side)", "UNEXPECTED payout");
} catch {
  line("alice (NO, losing side)", "0 — NothingToClaim (correct)");
}
line("contract balance", `${formatEther(await publicClient.getBalance({ address: predict.address }))} RITUAL (pool fully paid out)`);

console.log("");
console.log("── Market status ─────────────────────────────────────────");
for (const m of await predict.read.getMarkets()) {
  const pool = m.totalYes + m.totalNo;
  console.log(`  #${m.id} ${m.question}`);
  console.log(`     ${MARKET_STATE[m.state]} · ${OUTCOME[m.outcome]} · pool ${formatEther(pool)} RITUAL · observed $${m.observedValue}`);
}
console.log("");
console.log("Done. The market resolved itself — no cron, no backend, no resolve button.");

await connection.close();
