# Ritual Predict

A self-resolving binary prediction market on [Ritual Chain](https://docs.ritualfoundation.org).

Create a market like _"Will ETH/USD be at least $4,000 when this market resolves?"_, stake native
RITUAL on YES or NO, and watch it settle itself. When the betting window closes, **nobody presses a
resolve button and no backend cron job runs**. The Ritual Scheduler wakes the contract at a block
fixed when the market was created; the contract calls the HTTP precompile to read the configured
oracle URL, extracts one number with the jq precompile, compares it to the target, and settles.
Winners then pull their proportional share of the pool.

---

## Architecture

```
                 createMarket()                    ┌──────────────────────────┐
   user  ─────────────────────────────────────────▶│  RitualPredict.sol       │
   user  ─────────── bet(id, YES|NO) ─────────────▶│                          │
                                                   │  markets, pools, stakes  │
                                     schedule() ◀──┤                          │
                                                   └──────────────────────────┘
    ┌─────────────────────────────┐                     ▲              │
    │ Scheduler  0x56e7…D58B      │  onScheduledResolve │              │ deposit()
    │ system contract             │─────────────────────┘              ▼
    │ fires at resolveBlock,      │                        ┌────────────────────────┐
    │ 3 attempts, 200 blocks apart│                        │ RitualWallet 0x532F…   │
    └─────────────────────────────┘                        │ prepaid execution fees │
                                                           └────────────────────────┘
                        inside that one scheduled transaction:

   TEEServiceRegistry 0x9644…  ──pickServiceByCapability(HTTP_CALL)──▶  executor address
   HTTP precompile    0x0801   ──GET oracleUrl (in a TEE)───────────▶  demo oracle
   jq  precompile     0x0803   ──jsonPath, outputType=uint256───────▶  observed value
                                          │
                                          ▼
                        observed ⋈ target  →  Resolved(YES|NO)
                        read failed 3×     →  Invalid (everyone refunds)
```

---

### Design decisions worth knowing

**Deadlines are block numbers, not timestamps.** The Scheduler fires at a _block_, so betting also
closes at a _block_. That way "betting is closed" and "the Scheduler woke us" can never disagree,
whatever the chain's block time does. `createMarket` takes human durations in seconds and converts
them using the `blockTimeMs` fixed at deployment. Nothing on-chain reads `block.timestamp`.

**On Ritual Chain, `block.timestamp` is Unix milliseconds** (≈`1.786e12`), not seconds — verified
against the live chain, not assumed. That is a good reason to avoid it entirely, which this contract
does. Measured block time was ≈195 ms when this was written; run
`npx hardhat run scripts/block-time.ts` to check it for yourself.

**A failed oracle read is never a NO.** `onScheduledResolve` treats a precompile failure, a non-200
response, an undecodable envelope, an executor error message, and an unparseable body all as
_failures_, not as a negative outcome. The response decode happens through an external `try`, so
malformed bytes surface as a caught failure instead of reverting the execution and rolling back the
attempt counter.

**Retries are the Scheduler's own mechanism.** `createMarket` books `numCalls = 3` executions
`frequency = 200` blocks apart in a single `schedule()` call. Attempt 1 lands at `resolveBlock`; if
it succeeds, the contract `cancel()`s the remainder; if all three fail, the market becomes `Invalid`
and every stake is refundable. Each attempt re-rolls the TEE executor seed, so one unhealthy
executor cannot sink a market. The callback is idempotent, so a leftover execution is harmless.

**No executor is hardcoded.** The contract calls
`TEEServiceRegistry.pickServiceByCapability(HTTP_CALL, true, seed, 8)` at resolution time.

**Payouts are pull-based and loop-free.** `claimWinnings` computes
`stake × totalPool ÷ winningPool` for the caller only. Integer division leaves sub-wei dust in the
contract; that is deliberate and negligible.

**Empty winning side → refundable.** Pari-mutuel has no denominator when nobody backed the winning
answer, so the market records the outcome and observed value, then becomes `Invalid` so everyone
takes their stake back.

**Resolution parameters are immutable.** `target`, `comparator`, `oracleUrl`, `jsonPath`, and
`resolveBlock` have no setter. The `ResolutionRuleSet` event records them at creation.

---

## Prerequisites

- Node.js 20+ and `pnpm`
- A wallet with testnet RITUAL from <https://faucet.ritualfoundation.org>

## Setup

```bash
cd hardhat
pnpm install
cp .env.example .env
```

---

## Scope

Intentionally not included: an AMM, an order book, an order-matching engine, governance, a separate
ERC-20, a centralized resolver, or an upgrade proxy. Staking uses the chain's native asset and the
betting model is plain pari-mutuel: two running totals and one mapping per side.

## This fork's work (Bootcamp 2 submission)

The starter repo left five core functions stubbed out (`createMarket`,
`onScheduledResolve`, `_readOracle`, `_pickExecutor`, `_scheduleResolution`) and
referenced mocks + end-to-end tests that were not included. This fork implements
all of it and verifies it locally (the chain was down, so everything runs against
mocks at the canonical Ritual addresses — zero network, zero funds):

- **`hardhat/contracts/RitualPredict.sol`** — all five stubs implemented:
  duration/string validation, block-number deadlines, `Scheduler.schedule()`
  with 3 attempts 200 blocks apart, a revert-free idempotent scheduler callback
  (failures count, only the comparison decides the outcome, remaining executions
  are cancelled on a terminal state), the 13-field HTTP precompile (0x0801)
  request, an external-`try` envelope decode, jq (0x0803) extraction, and a
  re-seeded TEE executor pick per attempt.
- **`hardhat/contracts/mocks/RitualMocks.sol`** — stand-ins for the Scheduler,
  RitualWallet, TEEServiceRegistry, and the HTTP/jq precompiles, etched at the
  canonical addresses in tests.
- **`hardhat/contracts/RitualPredict.t.sol`** — 30 Solidity tests incl. two
  fuzz suites (payouts preserve the pool; all four comparators settle
  correctly), covering lifecycle, payouts, retries, invalidations, refunds,
  idempotency, and funding.
- **`hardhat/test/RitualPredict.e2e.ts`** — 2 end-to-end tests of the full
  workshop flow: the Scheduler wakes the contract, the market resolves itself,
  winners pull their share; and three failed oracle reads → `Invalid` → refunds.
- **`hardhat/scripts/local-demo.ts`** — run the whole lifecycle against a local
  `npx hardhat node` (offline demo): `npx hardhat node` in one terminal,
  `npx hardhat run scripts/local-demo.ts` in another.

Verification (2026-08-19): `npx hardhat test` → **32 passing**
(30 solidity, 2 nodejs); `npx tsc --noEmit` clean; the local-node demo runs
end-to-end (deploy → fund → create → bet → window closes → Scheduler fires →
Resolved → payouts, contract ends at 0 balance).

Fixes applied to the starter so it builds in this environment (network-blocked
github.com): `forge-std` is fetched from a codeload tarball instead of the git
protocol; `test/Counter.ts` was removed (it referenced a `Counter.sol` that does
not exist in this repo); `tsconfig.json` gained `noEmit` +
`allowImportingTsExtensions` (the upstream scripts import `.ts` extensions and
never typechecked). The `localRitual` network deliberately has no `chainId`
(hardhat node serves 31337) and impersonated accounts are funded for gas via
`hardhat_setBalance`.

See **WORKLOG.md** for the full debugging notes (including a solc 0.8.28
miscompile of large `abi.decode` calls that forced assembly-based calldata
parsing in the HTTP mock).

## Reference

- Ritual Chain docs — <https://docs.ritualfoundation.org>
- dApp skills — <https://github.com/ritual-foundation/ritual-dapp-skills>
- Explorer — <https://explorer.ritualfoundation.org> · Faucet — <https://faucet.ritualfoundation.org>
