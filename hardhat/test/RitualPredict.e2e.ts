import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { parseEther } from "viem";

import { RITUAL } from "../scripts/ritual.ts";

/**
 * End-to-end walkthroughs of the workshop flow, entirely local: the Ritual
 * system contracts and precompiles are mocked with `hardhat_setCode` at their
 * canonical addresses, so no chain connection and no real funds are needed.
 */
describe("RitualPredict end-to-end", async function () {
  const { viem, networkHelpers } = await network.create();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();
  const [deployer, alice, bob] = await viem.getWalletClients();

  const EXECUTOR = "0x000000000000000000000000000000000000007E";

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
      const mock = await viem.deployContract(name);
      const runtimeCode = (await publicClient.getCode({ address: mock.address }))!;
      await testClient.setCode({ address, bytecode: runtimeCode });
    }
  }

  it("resolves a market by itself and pays out winners", async function () {
    await etchMocks();

    // Point the oracle at a bullish ETH: 4200 >= 4000 → YES wins.
    const http = await viem.getContractAt("MockHTTPPrecompile", RITUAL.httpPrecompile);
    const jq = await viem.getContractAt("MockJQPrecompile", RITUAL.jqPrecompile);
    const registry = await viem.getContractAt("MockTEEServiceRegistry", RITUAL.teeServiceRegistry);
    await http.write.setResponse([200, "0x7b227072696365223a20343230307d", ""]); // {"price": 4200}
    await jq.write.setResult([4200n, true]);
    await registry.write.setExecutor([EXECUTOR, true]);

    const predict = await viem.deployContract("RitualPredict", [200n]);

    // Prepay execution fees into RitualWallet (this is what pays the Scheduler
    // and the HTTP precompile on the real chain).
    await predict.write.fundExecution([500000n], { value: parseEther("0.5") });
    assert.equal(await predict.read.executionBalance(), parseEther("0.5"));

    const createdBlock = await publicClient.getBlockNumber();
    const createHash = await predict.write.createMarket([
      {
        question: "Will ETH/USD be at least $4,000 when this market resolves?",
        oracleUrl: "https://oracle.example/eth",
        jsonPath: ".price",
        target: 4000n,
        comparator: 1, // GTE
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);
    const createReceipt = await publicClient.waitForTransactionReceipt({ hash: createHash });

    // 60s betting @ 200ms/block = 300 blocks; 30s delay = 150 blocks.
    // closeBlock/resolveBlock are computed from block.number INSIDE the create tx,
    // so anchor the expectation to the receipt's block.
    const market = await predict.read.getMarket([1n]);
    assert.equal(market.question, "Will ETH/USD be at least $4,000 when this market resolves?");
    assert.equal(market.closeBlock, createReceipt.blockNumber + 300n);
    assert.equal(market.resolveBlock, createReceipt.blockNumber + 450n);
    assert.equal(market.scheduleId, 1n);

    // Bets: alice YES 1.5, bob NO 1 → pool 2.5.
    await predict.write.bet([1n, true], { value: parseEther("1.5"), account: alice.account });
    await predict.write.bet([1n, false], { value: parseEther("1"), account: bob.account });

    // Betting window closes...
    await networkHelpers.mine(301);
    const closedView = await predict.read.getMarket([1n]);
    assert.equal(closedView.state, 1); // Closed

    // ...and the Scheduler wakes the contract. Nobody presses a button.
    await publicClient.request({
      method: "hardhat_impersonateAccount",
      params: [RITUAL.scheduler],
    } as never);
    await publicClient.request({
      method: "hardhat_setBalance",
      params: [RITUAL.scheduler, "0xDE0B6B3A7640000"], // 1 ETH for gas
    } as never);
    const schedulerWallet = await viem.getWalletClient(RITUAL.scheduler);
    await schedulerWallet.writeContract({
      address: predict.address,
      abi: predict.abi,
      functionName: "onScheduledResolve",
      args: [0n, 1n],
    });

    const resolved = await predict.read.getMarket([1n]);
    assert.equal(resolved.state, 3); // Resolved
    assert.equal(resolved.outcome, 1); // Yes
    assert.equal(resolved.observedValue, 4200n);
    assert.equal(resolved.attempts, 1);

    // Winners pull their share: alice 1.5 × 2.5 / 1.5 = 2.5.
    const aliceBefore = await publicClient.getBalance({ address: alice.account.address });

    await predict.write.claimWinnings([1n], { account: alice.account });
    await viem.assertions.revertWithCustomError(
      predict.write.claimWinnings([1n], { account: bob.account }),
      predict,
      "NothingToClaim",
    ); // losing side gets nothing

    const aliceAfter = await publicClient.getBalance({ address: alice.account.address });
    // The 2.5 pool goes to alice minus the claim tx's gas; the contract ends empty.
    const aliceGain = aliceAfter - aliceBefore;
    assert.ok(aliceGain > parseEther("2.4") && aliceGain <= parseEther("2.5"), "alice should net ~2.5");
    assert.equal(await publicClient.getBalance({ address: predict.address }), 0n);

    // bob backed the losing side: stake intact, nothing claimable, never settled.
    const bobStakes = await predict.read.stakesOf([1n, bob.account.address]);
    assert.equal(bobStakes[1], parseEther("1")); // bob's NO stake
    assert.equal(bobStakes[2], false);
    assert.equal(bobStakes[3], 0n);
  });

  it("invalidates a market after three failed oracle reads and refunds everyone", async function () {
    await etchMocks();

    const http = await viem.getContractAt("MockHTTPPrecompile", RITUAL.httpPrecompile);
    const jq = await viem.getContractAt("MockJQPrecompile", RITUAL.jqPrecompile);
    const registry = await viem.getContractAt("MockTEEServiceRegistry", RITUAL.teeServiceRegistry);
    await jq.write.setResult([1n, true]);
    await registry.write.setExecutor([EXECUTOR, true]);
    await http.write.setRevertCall([true]);

    const predict = await viem.deployContract("RitualPredict", [200n]);
    const createHash = await predict.write.createMarket([
      {
        question: "Will ETH reach 4000?",
        oracleUrl: "https://oracle.example/eth",
        jsonPath: ".price",
        target: 4000n,
        comparator: 1,
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);
    await publicClient.waitForTransactionReceipt({ hash: createHash });

    await predict.write.bet([1n, true], { value: parseEther("1"), account: alice.account });

    await publicClient.request({
      method: "hardhat_impersonateAccount",
      params: [RITUAL.scheduler],
    } as never);
    await publicClient.request({
      method: "hardhat_setBalance",
      params: [RITUAL.scheduler, "0xDE0B6B3A7640000"], // 1 ETH for gas
    } as never);
    const schedulerWallet = await viem.getWalletClient(RITUAL.scheduler);

    // Attempts 1..3 all fail; the third failure invalidates the market.
    for (let i = 0n; i < 3n; i++) {
      await schedulerWallet.writeContract({
        address: predict.address,
        abi: predict.abi,
        functionName: "onScheduledResolve",
        args: [i, 1n],
      });
    }

    const market = await predict.read.getMarket([1n]);
    assert.equal(market.state, 4); // Invalid
    assert.equal(market.attempts, 3);
    assert.equal(market.invalidReason, "http precompile call failed");

    const aliceBefore = await publicClient.getBalance({ address: alice.account.address });
    await predict.write.claimRefund([1n], { account: alice.account });
    const aliceAfter = await publicClient.getBalance({ address: alice.account.address });
    // Full 1 ETH refund minus the refund tx's gas; the contract ends empty.
    const aliceGain = aliceAfter - aliceBefore;
    assert.ok(aliceGain > parseEther("0.9") && aliceGain <= parseEther("1"), "alice should net ~1 ETH");
    assert.equal(await publicClient.getBalance({ address: predict.address }), 0n);
  });
});
