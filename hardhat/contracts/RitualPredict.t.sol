// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {
    MockScheduler,
    MockRitualWallet,
    MockTEEServiceRegistry,
    MockHTTPPrecompile,
    MockJQPrecompile
} from "./mocks/RitualMocks.sol";

/**
 * Unit tests for RitualPredict. Every Ritual system contract and precompile is
 * replaced by a mock etched at its canonical address (see RitualMocks.sol), so
 * the whole suite runs locally with zero network access and zero real funds.
 */
contract RitualPredictTest is Test {
    // 200 ms/block → 60s betting = 300 blocks, 30s delay = 150 blocks.
    uint256 internal constant BLOCK_TIME_MS = 200;
    uint256 internal constant BETTING_SECONDS = 60;
    uint256 internal constant DELAY_SECONDS = 30;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B0);
    address internal constant CAROL = address(0xCA701);
    address internal constant EXECUTOR = address(0x7EE);

    RitualPredict internal predict;
    MockScheduler internal scheduler;
    MockRitualWallet internal wallet;
    MockTEEServiceRegistry internal registry;
    MockHTTPPrecompile internal http;
    MockJQPrecompile internal jq;

    function setUp() public {
        // Etch mocks BEFORE deploying RitualPredict: its constructor calls
        // Scheduler.approveScheduler().
        vm.etch(RitualChain.SCHEDULER, address(new MockScheduler()).code);
        vm.etch(RitualChain.RITUAL_WALLET, address(new MockRitualWallet()).code);
        vm.etch(
            RitualChain.TEE_SERVICE_REGISTRY,
            address(new MockTEEServiceRegistry()).code
        );
        vm.etch(RitualChain.HTTP_PRECOMPILE, address(new MockHTTPPrecompile()).code);
        vm.etch(RitualChain.JQ_PRECOMPILE, address(new MockJQPrecompile()).code);

        // Default oracle behaviour: ETH at 4200 ≥ target 4000 → YES wins.
        http = MockHTTPPrecompile(payable(RitualChain.HTTP_PRECOMPILE));
        jq = MockJQPrecompile(RitualChain.JQ_PRECOMPILE);
        registry = MockTEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY);
        scheduler = MockScheduler(payable(RitualChain.SCHEDULER));
        wallet = MockRitualWallet(payable(RitualChain.RITUAL_WALLET));

        http.setResponse(200, bytes("{\"price\": 4200}"), "");
        jq.setResult(4200, true);
        registry.setExecutor(EXECUTOR, true);

        predict = new RitualPredict(BLOCK_TIME_MS);
    }

    // ──────────────────────────── helpers ────────────────────────────

    function _params() internal pure returns (RitualPredict.NewMarket memory) {
        return
            RitualPredict.NewMarket({
                question: "Will ETH/USD reach 4000?",
                oracleUrl: "https://oracle.example/eth",
                jsonPath: ".price",
                target: 4000,
                comparator: RitualPredict.Comparator.GTE,
                bettingSeconds: BETTING_SECONDS,
                resolveDelaySeconds: DELAY_SECONDS
            });
    }

    function _newMarket() internal returns (uint256) {
        return predict.createMarket(_params());
    }

    function _bet(address who, uint256 id, bool isYes, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        predict.bet{value: amount}(id, isYes);
    }

    /// Fire the scheduled callback exactly like the real Scheduler: same caller,
    /// real executionIndex written into the calldata slot.
    function _fireResolution(uint256 id, uint256 executionIndex) internal {
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(executionIndex, id);
    }

    function _rollToResolve(uint256 id) internal {
        vm.roll(predict.getMarket(id).resolveBlock);
    }

    // ─────────────────────── market creation ─────────────────────────

    function test_CreateMarket_StoresRuleAndEmitsEvents() public {
        uint256 closeBlock = block.number + (BETTING_SECONDS * 1000) / BLOCK_TIME_MS;
        uint256 resolveBlock = closeBlock + (DELAY_SECONDS * 1000) / BLOCK_TIME_MS;

        vm.expectEmit(true, true, false, true, address(predict));
        emit RitualPredict.MarketCreated(
            1,
            address(this),
            "Will ETH/USD reach 4000?",
            uint64(closeBlock),
            uint64(resolveBlock),
            1
        );
        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionRuleSet(
            1,
            "https://oracle.example/eth",
            ".price",
            4000,
            RitualPredict.Comparator.GTE
        );

        uint256 id = _newMarket();
        assertEq(id, 1);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.creator, address(this));
        assertEq(m.question, "Will ETH/USD reach 4000?");
        assertEq(m.oracleUrl, "https://oracle.example/eth");
        assertEq(m.jsonPath, ".price");
        assertEq(m.target, 4000);
        assertEq(uint8(m.comparator), uint8(RitualPredict.Comparator.GTE));
        assertEq(m.closeBlock, uint64(closeBlock));
        assertEq(m.resolveBlock, uint64(resolveBlock));
        assertEq(m.scheduleId, 1);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Open));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Unresolved));
    }

    function test_CreateMarket_SchedulesWithScheduler() public {
        _newMarket();

        // The mock scheduler recorded the schedule call.
        assertEq(scheduler.lastCallId(), 1);
        assertEq(scheduler.lastStartBlock(), uint32(predict.getMarket(1).resolveBlock));
        assertEq(scheduler.lastNumCalls(), predict.MAX_ATTEMPTS());
        assertEq(scheduler.lastFrequency(), predict.RETRY_INTERVAL_BLOCKS());

        // data = onScheduledResolve(executionIndex=0 placeholder, marketId=1)
        bytes memory expected = abi.encodeWithSelector(
            predict.onScheduledResolve.selector,
            uint256(0),
            uint256(1)
        );
        assertEq(keccak256(scheduler.lastData()), keccak256(expected));
    }

    function test_CreateMarket_Reverts_EmptyStrings() public {
        RitualPredict.NewMarket memory p = _params();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);

        p = _params();
        p.oracleUrl = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);

        p = _params();
        p.jsonPath = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        predict.createMarket(p);
    }

    function test_CreateMarket_Reverts_BadDurations() public {
        RitualPredict.NewMarket memory p = _params();
        p.bettingSeconds = predict.MIN_BETTING_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);

        p = _params();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS() - 1;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);

        p = _params();
        p.bettingSeconds = predict.MAX_MARKET_SECONDS() - 1;
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS() + 1; // total over 1 day
        vm.expectRevert(RitualPredict.BadDuration.selector);
        predict.createMarket(p);
    }

    // ─────────────────────────── betting ─────────────────────────────

    function test_Bet_TracksStakesAndEmits() public {
        uint256 id = _newMarket();

        vm.expectEmit(true, true, false, true, address(predict));
        emit RitualPredict.BetPlaced(id, ALICE, true, 1 ether);

        _bet(ALICE, id, true, 1 ether);
        _bet(BOB, id, true, 0.5 ether);
        _bet(CAROL, id, false, 2 ether);

        assertEq(predict.yesStake(id, ALICE), 1 ether);
        assertEq(predict.yesStake(id, BOB), 0.5 ether);
        assertEq(predict.noStake(id, CAROL), 2 ether);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, 1.5 ether);
        assertEq(m.totalNo, 2 ether);
    }

    function test_Bet_Reverts_ZeroStake() public {
        uint256 id = _newMarket();
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet{value: 0}(id, true);
    }

    function test_Bet_Reverts_UnknownMarket() public {
        vm.deal(ALICE, 1 ether); // the pranked account pays, so fund it
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.bet{value: 1 ether}(99, true);
    }

    function test_Bet_Reverts_AfterCloseBlock() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        vm.roll(predict.getMarket(id).closeBlock);
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(id, false);
    }

    // ───────────────────────── resolution ────────────────────────────

    function test_Resolve_YesWins_PaysProportionalShares() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1.5 ether);
        _bet(BOB, id, true, 0.5 ether);
        _bet(CAROL, id, false, 2 ether);

        _rollToResolve(id);
        vm.expectEmit(true, false, false, true, address(predict));
        emit RitualPredict.ResolutionAttempted(id, 1, EXECUTOR);
        _fireResolution(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, 4200);
        assertEq(m.attempts, 1);

        // alice: 1.5 × 4 / 2 = 3, bob: 0.5 × 4 / 2 = 1, carol: 0
        vm.prank(ALICE);
        predict.claimWinnings(id);
        assertEq(ALICE.balance, 3 ether);

        vm.prank(BOB);
        predict.claimWinnings(id);
        assertEq(BOB.balance, 1 ether);

        vm.prank(CAROL);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);
    }

    function test_Resolve_NoWins() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);
        _bet(CAROL, id, false, 2 ether);

        // Oracle now reads 3900 < 4000 → NO wins.
        http.setResponse(200, bytes("{\"price\": 3900}"), "");
        jq.setResult(3900, true);

        _rollToResolve(id);
        _fireResolution(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.No));

        // carol: 2 × 3 / 2 = 3 (wins the whole pool); alice gets nothing.
        vm.prank(CAROL);
        predict.claimWinnings(id);
        assertEq(CAROL.balance, 3 ether);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);
    }

    function test_Resolve_EmptyWinningSide_InvalidatesAndRefunds() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, false, 1 ether); // only NO bets
        _bet(BOB, id, false, 0.5 ether);

        _rollToResolve(id);
        _fireResolution(id, 0);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.invalidReason, "no bets on the winning side");

        vm.prank(ALICE);
        predict.claimRefund(id);
        assertEq(ALICE.balance, 1 ether);

        vm.prank(BOB);
        predict.claimRefund(id);
        assertEq(BOB.balance, 0.5 ether);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimRefund(id);
    }

    function test_Resolve_ThreeFailures_InvalidatesAndRefunds() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        http.setRevertCall(true);
        _rollToResolve(id);

        _fireResolution(id, 0);
        assertEq(predict.getMarket(id).attempts, 1);
        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );

        _fireResolution(id, 1);
        assertEq(predict.getMarket(id).attempts, 2);

        _fireResolution(id, 2);
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(m.attempts, 3);
        assertEq(m.invalidReason, "http precompile call failed");

        vm.prank(ALICE);
        predict.claimRefund(id);
        assertEq(ALICE.balance, 1 ether);
    }

    function test_Resolve_FailThenSucceed_RetryRecovers() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        http.setRevertCall(true);
        _rollToResolve(id);
        _fireResolution(id, 0);
        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );

        // Executor recovers; attempt 2 succeeds.
        http.setRevertCall(false);
        _fireResolution(id, 1);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.attempts, 2);
    }

    function test_Resolve_Non200Status_Fails() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        http.setResponse(503, bytes(""), "upstream down");
        _rollToResolve(id);
        _fireResolution(id, 0);

        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );
    }

    function test_Resolve_ExecutorErrorMessage_Fails() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        http.setResponse(200, bytes("{}"), "executor exploded");
        _rollToResolve(id);
        _fireResolution(id, 0);

        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );
    }

    function test_Resolve_UndecodableEnvelope_Fails() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        // Malformed bytes from the chain → the external try catches, not revert.
        http.setRawOverride(hex"deadbeef");
        _rollToResolve(id);
        _fireResolution(id, 0);

        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );
        assertEq(predict.getMarket(id).attempts, 1);
    }

    function test_Resolve_NoExecutor_Fails() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        registry.setExecutor(address(0), false);
        _rollToResolve(id);
        _fireResolution(id, 0);

        assertEq(predict.getMarket(id).attempts, 1);
        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Resolving)
        );
    }

    function test_Resolve_Reverts_OnlyScheduler() public {
        uint256 id = _newMarket();
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, id);
    }

    function test_Resolve_Reverts_UnknownMarket() public {
        vm.prank(RitualChain.SCHEDULER);
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.onScheduledResolve(0, 99);
    }

    function test_Resolve_IsIdempotent_AndCancelsRemainder() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);

        _rollToResolve(id);
        _fireResolution(id, 0);
        assertEq(scheduler.cancelCount(), 1);

        // A leftover execution (scheduler drift) must be a no-op.
        _fireResolution(id, 1);
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.attempts, 1);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(scheduler.cancelCount(), 1); // no second cancel
    }

    // ─────────────────────────── payouts ─────────────────────────────

    function test_Claim_Reverts_BeforeResolve() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.NotResolved.selector);
        predict.claimWinnings(id);
    }

    function test_Claim_Reverts_Twice() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1.5 ether);
        _bet(CAROL, id, false, 0.5 ether);

        _rollToResolve(id);
        _fireResolution(id, 0);

        vm.prank(ALICE);
        predict.claimWinnings(id);
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(id);
    }

    function test_Refund_Reverts_OnResolvedMarket() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1 ether);
        _rollToResolve(id);
        _fireResolution(id, 0);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        predict.claimRefund(id);
    }

    // ──────────────────────────── views ──────────────────────────────

    function test_GetMarket_FlipsOpenToClosed() public {
        uint256 id = _newMarket();
        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Open)
        );

        vm.roll(predict.getMarket(id).closeBlock);
        assertEq(
            uint8(predict.getMarket(id).state),
            uint8(RitualPredict.MarketState.Closed)
        );
    }

    function test_StakesOf_ReportsClaimable() public {
        uint256 id = _newMarket();
        _bet(ALICE, id, true, 1.5 ether);
        _bet(CAROL, id, false, 0.5 ether);

        (uint256 yes, uint256 no, bool settled, uint256 claimable) = predict
            .stakesOf(id, ALICE);
        assertEq(yes, 1.5 ether);
        assertEq(no, 0);
        assertFalse(settled);
        assertEq(claimable, 0); // not resolved yet

        _rollToResolve(id);
        _fireResolution(id, 0);

        (yes, no, settled, claimable) = predict.stakesOf(id, ALICE);
        assertEq(claimable, 2 ether); // 1.5 × 2 / 1.5
        (yes, no, settled, claimable) = predict.stakesOf(id, CAROL);
        assertEq(claimable, 0); // losing side
    }

    function test_GetMarkets_ReturnsNewestFirst() public {
        _newMarket();
        _newMarket();
        RitualPredict.Market[] memory markets = predict.getMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0].id, 2);
        assertEq(markets[1].id, 1);
    }

    // ─────────────────────── execution funding ───────────────────────

    function test_FundExecution_DepositsToWallet() public {
        predict.fundExecution{value: 0.5 ether}(500_000);
        assertEq(wallet.balanceOf(address(predict)), 0.5 ether);
        assertEq(predict.executionBalance(), 0.5 ether);
        assertEq(wallet.lockUntil(address(predict)), block.number + 500_000);
    }

    function test_FundExecution_Reverts_ZeroValue() public {
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.fundExecution{value: 0}(500_000);
    }

    // ───────────────────────────── fuzz ──────────────────────────────

    /// Whatever the stakes, the winners collectively take the whole pool (minus
    /// sub-wei integer dust) and nobody gets less than their stake back.
    function testFuzz_PayoutsPreserveThePool(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 1000 ether);
        b = bound(b, 1, 1000 ether);
        c = bound(c, 1, 1000 ether);

        uint256 id = _newMarket();
        _bet(ALICE, id, true, a);
        _bet(BOB, id, true, b);
        _bet(CAROL, id, false, c);

        _rollToResolve(id);
        _fireResolution(id, 0); // YES wins (4200 >= 4000)

        (uint256 pool) = a + b + c;
        (uint256 claimAlice) = (a * pool) / (a + b);
        (uint256 claimBob) = (b * pool) / (a + b);

        vm.prank(ALICE);
        predict.claimWinnings(id);
        assertEq(ALICE.balance, claimAlice);

        vm.prank(BOB);
        predict.claimWinnings(id);
        assertEq(BOB.balance, claimBob);

        // Each winner at least doubles... no: each recovers ≥ their stake.
        assertGe(claimAlice, a);
        assertGe(claimBob, b);

        // Dust: the sum of truncated divisions can never lose more than 2 wei.
        uint256 dust = pool - claimAlice - claimBob;
        assertLe(dust, 2);
        assertLe(address(predict).balance, 2);
    }

    /// All four comparators settle exactly as their operator says.
    function testFuzz_ComparatorSemantics(uint8 comp, uint256 observed, uint256 target) public {
        comp = uint8(bound(comp, 0, 3));
        observed = bound(observed, 0, 1_000_000);
        target = bound(target, 0, 1_000_000);

        RitualPredict.NewMarket memory p = _params();
        p.target = target;
        p.comparator = RitualPredict.Comparator(comp);
        uint256 id = predict.createMarket(p);

        _bet(ALICE, id, true, 1 ether);
        http.setResponse(200, bytes("{\"price\": 1}"), "");
        jq.setResult(observed, true);

        _rollToResolve(id);
        _fireResolution(id, 0);

        bool expectYes = comp == 0
            ? observed > target
            : comp == 1
                ? observed >= target
                : comp == 2
                    ? observed < target
                    : observed <= target;
        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(
            uint8(m.outcome),
            expectYes ? uint8(RitualPredict.Outcome.Yes) : uint8(RitualPredict.Outcome.No),
            "comparator settled wrong"
        );
    }
}
