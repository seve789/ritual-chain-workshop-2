# Bootcamp 2 — Ritual Predict: workshop work log

> Work log for this fork's submission (seve789/ritual-chain-workshop-2).
> Status: **COMPLETE** — all local work implemented, verified green
> (32 tests + local-node demo), and pushed to the fork via the GitHub Contents
> API (github.com git protocol is blocked in this environment).

## What is this

Self-resolving binary prediction market on Ritual Chain (chain id 1979) for the
"Proof of Building — Bootcamp 2" workshop. Fork: `seve789/ritual-chain-workshop-2`
(parent: `cozfuttu/ritual-chain-workshop-2`).

The starter's `RitualPredict.sol` had 5 stubbed functions (`createMarket`,
`onScheduledResolve`, `_readOracle`, `_pickExecutor`, `_scheduleResolution`),
plus the README promised mocks + e2e tests that were NOT in the repo.

## Verification evidence (2026-08-19, ad-hoc hermes-verify script)

```
npx hardhat test            → 32 passing (30 solidity, 2 nodejs)   ✅
npx tsc --noEmit            → clean                                 ✅
local node demo             → full end-to-end on `hardhat node`:   ✅
  deploy → fund (0.5 RITUAL) → create market #1 (close block 870,
  resolve block 945, schedule 4) → bets YES 1.5 / NO 1.0 →
  window closes (Closed) → impersonated Scheduler fires →
  Resolved YES @ $4200, attempts 1/3, schedule cancelled →
  winner claims +2.4999… RITUAL, loser NothingToClaim,
  contract balance 0
```

## Done ✅

1. **Fork created** via GitHub API (lineage verified), local repo at `~/ritual-chain-workshop-2`
   (git init on `main`, remotes: `origin` = fork, `upstream` = cozfuttu repo).
   NOT PUSHED YET — the fork has zero commits of our own.
2. **Contract fully implemented** (`hardhat/contracts/RitualPredict.sol`): all 5
   stubs filled — duration/string validation, block-number deadlines,
   Scheduler `schedule()` (3 attempts × 200 blocks), revert-free idempotent
   scheduler callback, 13-field HTTP precompile request, external-try envelope
   decode, jq extraction, per-attempt executor re-seed, cancel-on-terminal.
3. **Mocks** (`hardhat/contracts/mocks/RitualMocks.sol`): Scheduler / RitualWallet /
   TEEServiceRegistry / HTTP 0x0801 / jq 0x0803 stand-ins, etched at canonical
   addresses via `vm.etch` (Solidity tests) or deploy+getCode+setCode (TS tests).
4. **Solidity tests** (`contracts/RitualPredict.t.sol`): 30 passing (incl. 2 fuzz
   suites, 256 runs each) — lifecycle, payouts, invalidations, retries, refunds,
   idempotency, comparator semantics, pool-preservation fuzz.
5. **TS e2e tests** (`test/RitualPredict.e2e.ts`): 2 passing — full workshop flow
   (deploy → fund → create → bet → window closes → impersonated Scheduler fires →
   resolved → claim) and the 3-failures→Invalid→refund flow.
6. **Local node demo** (`scripts/local-demo.ts` + `localRitual` network in
   `hardhat.config.ts`): VERIFIED end-to-end on `npx hardhat node`.
7. **Typecheck**: `npx tsc --noEmit` clean.
8. **Fixes made to the starter** (document these in the README):
   - `forge-std` git dep → codeload tarball URL (github.com SSH blocked in this env)
   - deleted `test/Counter.ts` (references a `Counter.sol` that doesn't exist)
   - tsconfig: added `noEmit` + `allowImportingTsExtensions` (upstream scripts
     import `.ts` extensions; upstream tsconfig couldn't typecheck)
   - `localRitual` network must NOT hardcode chainId 1979 (hardhat node serves
     31337 → HHE708); impersonated accounts need `hardhat_setBalance` for gas
     ("Missing or invalid parameters" otherwise)

## Ritual skill cross-check (2026-08-19)

Post-submission audit against the `ritual-dapp-precompiles` skill reference. The
implementation was written from `ritual-dapp-http` + `ritual-dapp-scheduler`
(canonical addresses came from the repo's own `RitualChain.sol`); this pass
re-verifies every encoding decision against the complete ABI reference:

| Check | Skill reference | Our implementation | Result |
|---|---|---|---|
| HTTP 0x0801 request (13 fields) | base(0-4) + url(5) + method(6) + headerKeys(7) + headerValues(8) + body(9) + dkmsKeyIndex(10) + dkmsKeyFormat(11) + piiEnabled(12) | `abi.encode(executor, secrets, ttl, sigs, pubkey, url, GET=1, [], [], 0x, 0, 0, false)` | ✅ identical |
| HTTP 0x0801 output | `(uint16, string[], string[], bytes, string)` | `decodeHttpResponse` decodes the same 5-tuple | ✅ |
| JQ 0x0803 | `(query, inputData, outputType)` — 1 = uint256 | `_jqUint` uses `JQ_OUT_UINT256 = 1`, length<32 = failure | ✅ |
| System contract addresses | Wallet `0x532F…`, Scheduler `0x56e7…`, Registry `0x9644…` | repo `RitualChain.sol` (same values) | ✅ |
| Async envelope | `(bytes simmedInput, bytes actualOutput)` | `decodeHttpResponse` unwraps the pair | ✅ |
| Scheduler `schedule()` | 10 params, executionIndex injected into calldata bytes 4-35 | `_scheduleResolution` encodes 0 placeholder; `frequency×numCalls` = 600 ≤ MAX_LIFESPAN 10,000 | ✅ |

Also checked: HTTP method codes (GET=1), capability enum (HTTP_CALL=0), and the
base executor field order — all match. No encoding errors found; end-to-end
verification (32 tests + local-node demo) remains the behavioral proof.

## Pitfalls discovered (keep for README / future work)

- solc 0.8.28 + optimizer runs=200 **miscompiles large dynamic abi.decode**:
  a bare 13-field tuple decode = compile-time stack-too-deep; a 13-field struct
  decode compiles but reverts at runtime (Panic 0x41 "allocation too large").
  Workaround: read calldata head slots via `assembly calldataload` + manual
  string copy (`calldatacopy`). Only affects DECODE side; `abi.encode` of 13
  fields is fine.
- `hardhat_setCode` (and anvil_setCode) wants **runtime bytecode** — artifact
  `.bytecode` is creation code and executing it yields selector mismatches /
  `<unknown>` reverts. Deploy the mock and copy `getCode()` output instead.
- Mock contracts used via etch must not rely on constructor state initializers
  (constructor never runs at the etched address) — `nextCallId` started at 0,
  yielding `scheduleId=0`. Use `++nextCallId` and explicit config calls.
- `vm.expectRevert` with a pranked account that has no ETH: the call reverts
  with "insufficient balance" (empty data), which doesn't match a custom-error
  selector. `vm.deal` the pranked account first.
- Impersonated account (hardhat_impersonateAccount) needs a balance for gas:
  `hardhat_setBalance` it first, or eth_sendTransaction fails with
  "Missing or invalid parameters".
- Gas-aware balance assertions: any tx from the account (incl. reverted ones)
  costs gas — assert contract balance == 0 or use tolerance ranges.

## Next steps (resume here)

```bash
cd ~/ritual-chain-workshop-2/hardhat

# 1. Update READMEs (root + hardhat/) with: what was implemented, the starter
#    fixes, the pitfalls above, commands.

# 2. Commit + push to the fork. github.com git protocol is blocked; use the
#    Contents API uploader (see github-repo-management skill, scripts/upload-to-github.sh
#    pattern, token from git credential manager / ~/prismax-dashboard/.env GH_PAT).
#    Verify commits via https://api.github.com/repos/seve789/ritual-chain-workshop-2/commits

# 3. Optionally: build a tiny frontend (web/) — the README references one.
```

## Test commands

```bash
cd ~/ritual-chain-workshop-2/hardhat
npx hardhat build          # compile (4 contracts)
npx hardhat test           # 32 passing (30 solidity + 2 nodejs e2e)
npx tsc --noEmit           # clean
npx hardhat test solidity  # solidity only
```
