# Changes since `41a3485`

Post-review product pass: the farm-management rework of the Distributor, the remaining
checklist items across LoC / staking / escrow, the public renames, and the new fee
subsystem. At `37e8512` 601/602 tests passed (one broken BunniFeeDistributor fixture);
with the audit fixes at the bottom of this file the whole suite passes.

## Distributor (`src/farm/Distributor.sol`)

- **Deposit fees removed, harvest interval hardcoded** to 30 seconds; `setPool` deleted.
  The legacy `poolInfo` tuple keeps its shape (returns `0, 30`).
- **Per-stream managers**: `addStream` is now Owner-or-Admin and takes a `manager` who
  can set rates, epochs, pause/resume, recover unaccrued reserve, and hand over
  managership — on their own stream only. Every managed action spends the stream's own
  budget, so delegation adds no protocol risk.
- **MintRights**: per-token aggregate cap on MINT-stream rates. Increases are
  scheduled + applied after a 2-day delay; decreases are instant; MINT rate-setting
  dropped to Owner-or-Admin *within* the rights budget (rights start at zero).
- **Fixed epochs extended to PULL streams**: an epoch-mode PULL pulls its budget from
  the source at each period start — `setStreamEpochPull` caps the per-period draw so a
  source can grant one standing allowance instead of re-approving every epoch.
  `fundStream` is now BALANCE-only (a PULL stream's reserve only ever comes from its
  source's pulls).
- **Per-stream funding fee**: `fundFeeBps` moved from a global into the Stream (set at
  creation, Admin-adjustable via `setStreamFundFee`, ≤ 20%). Applies uniformly to
  `fundStream`, epoch pulls, and live pull realizations, so the funding mode never
  changes what a farm owes. Funders can pin the fee they accept via the
  `fundStream(..., maxFeeBps)` overload; protocol fee-routing streams simply use fee 0.
- **Stream replacement**: `replaceStream` (Owner) settles a slot, sweeps its residual
  (unaccrued reserve + accrued-but-unclaimed, in the old token) to a chosen address,
  and restarts the slot with a new token/kind/manager/fee. Stale user debt/lockups are
  voided lazily via a per-stream generation stamp. Makes the 8-slot cap recyclable.
- **Unlimited pools**: `MAX_POOLS` removed. `setIntermediary` now walks a dedicated
  hook-pool registry instead of every pool, and `massUpdatePools(start, end)` allows
  chunking, so pool count no longer degrades any control path.
- **Two-tier payout gas**: reward-token calls are capped at 150k inside hook-driven
  settles (a heavy token defers instead of bricking the stake token's transfers) and
  get 1M on explicit harvests (enough for any honest token; hostile gas-burners stay
  bounded and can never OOG a withdraw).
- **Farm-bound EscrowedToken support**: IStakingContract-shaped hook aliases
  (`notifyDeposit` / `notifyWithdraw`), a hook-token-gated `notifyReward` that credits
  penalty inflows to the pool's matching BALANCE stream fee-free, and `syncStake` now
  reads the hook token's `stakedSharesOf` (falling back to `balanceOf`) so vesting
  partial power cannot be stripped by third-party syncs.

## EscrowedToken (`src/token/EscrowedToken.sol`)

- **Conversion path (soft → harder lock)**, generalized for any escrow pair over the
  same underlying: `convertTo` burns the source, moves the ALB backing, and mints the
  destination 1:1 atomically, with combined staking shares continuous. Gated by dual
  Owner registries (`setConversionDestination` — validates same underlying — and
  `setConversionSource`); the destination's supply cap is the only limit. Wired for
  esALB → govALB.
- **`penaltySink`**: when set, early-exit penalties transfer straight to the sink
  instead of redistributing via `notifyReward`. Required for farm-bound escrows whose
  underlying is itself a hook token (hook tokens cannot be reward streams; the
  redistribution path would brick every early exit).
- **`distributor()` probe alias** returning the bound consumer, so a farm-bound escrow
  passes its farm's HOOK opt-in check (and a staking-bound token correctly fails it).

## StakingContract (`src/staking/StakingContract.sol`)

- **`reviveStream`** (Owner): stream retiring is no longer permanent — retire claws
  back the unemitted remainder, revive reopens the slot for fresh `notifyReward`
  funding. Safe by construction (the accumulator is never touched, so reward debts
  stay exact); reviving cancels the deletion clock. Deletion remains permanent.

## LoC (`src/loc/LoC.sol`)

- **Interest mints without a rebase** (`mintNoRebase`): the sink is the staking
  contract, so interest is already escrow-holder revenue — rebasing it paid them twice.
  Principal draws still rebase.

## Renames

- `NewALB` → **`ALBToken`**, `NewEsALB` → **`EsALB`**, `INewALB` → `IALB` (files moved
  with them; ~25 referencing files updated including the deploy script). ERC20 names
  are now **"Alien Base Token"**, "Escrowed Alien Base Token", "Governance Alien Base
  Token" — permit domain separators change with them (fine pre-deploy). The contract
  is not named `AlienBaseToken` because the legacy `contracts/alb/AlienBaseToken.sol`
  shares that source basename and forge's artifact layout collides on it.
- Comment cleanup: remaining history-narrating comments rewritten as present-tense
  invariants (AlbTwapSource `lastUpdate`), and the stray `????` scratch note in
  UniV3TwapOracle resolved into documentation of where orientation/decimals are
  actually enforced.

## New fee subsystem (`src/fees/`)

- **`FeeConverter`** — terminal sink for protocol fee revenue: swaps fee tokens to
  WETH through a whitelisted router (Epsilon) under oracle value invariants
  (calldata-opaque, POLHolder-style), streams WETH and ALB into the StakingContract,
  and runs an optional buyback-and-burn program (`burnBps`; ALB is never swapped).
  22 tests, complete.
- **`BunniFeeDistributor`** — collects swap fees from Bunni positions via
  BunniHubA `compoundSkim`, measured (never estimated), and splits them between the
  LP farm, protocol, referrer, and a caller bounty, with an unattributed-surplus
  ledger and an internal action timelock. **⚠ Not ready — do not deploy**:
  - Still targets the StakingContract's `notifyReward` shape; the planned rework
    routes the LP share into Distributor BALANCE streams via `fundStream` with a
    validated per-key `(farm, pid, index)` config (per-stream fee 0 makes the old
    double-skim concern moot).
  - One test fails on a fixture issue (`_newFarm(makeAddr("alb"), ...)` passes a
    codeless address; stream tokens must have code since `8fba641`).
  - Deployment requires transferring BunniHubA ownership to it and setting the hub's
    protocol fee to 1e18; neither sequencing is scripted yet.

## Docs and tests

- **`DISTRIBUTOR_MANUAL.md`** (new): role matrix, per-persona do's and don'ts, the
  farm-bound escrow integration contract, and the consolidated sharp-edges list.
- New suites: `DistributorManager.t.sol` (managers, epochs, fees, replacement,
  MintRights, payout gas), `FarmEscrow.t.sol` (farm-bound escrow lifecycle),
  `EscrowConvertAndRevive.t.sol` (conversion, revive, no-rebase interest),
  `FeeConverter.t.sol`, `BunniFeeDistributor.t.sol`.
- Adapted suites: `Distributor`, `DistributorEpoch`, `ProtocolNotesRegression`, and
  the zzaudit pins whose guarded invariants deliberately changed (Admin may now add
  streams bounded by MintRights; pool count is unbounded but flagging stays O(hook
  pools)).
- `FIXED_EMISSION_PERIODS.md` still describes the pre-extension epoch behavior
  (BALANCE-only, Owner-set); `DISTRIBUTOR_MANUAL.md` supersedes it on those points
  pending a reconciliation pass.

## Distributor audit fixes (post-`37e8512`)

Fixes for the Distributor audit round against `37e8512` (regressions:
`test/DistributorAuditFixes.t.sol`).

- **PULL sources (H-01)**: binding a stream to a PULL source (`addStream` /
  `replaceStream` with kind PULL) was made Owner-only — consent is per-source, so an
  Admin could attach its own stream to someone else's source. SUPERSEDED below
  ("Timelock governance"): the later per-stream-terms fix made binding fail-closed,
  so binding is Admin-level again. `recoverStreamReserve` on a PULL stream always
  pays `s.source` and ignores `to`.
- **Escrow exemptions (M-01)**: `syncStake` reads a hook token's `isHookExempt(user)`
  first; exempt accounts (an escrow's vesting custody, its consumer, exempted custodians)
  read as zero stake, so a third party can no longer enroll them. All probe reads are
  gas-bounded and copy at most one word; an unreadable balance reverts
  `BalanceReadFailed` instead of syncing anyone to zero.
- **Bounded token reads (M-02)**: the payout's balance read shares the payout stipend
  with its transfer (150k in hook settles, 1M on harvests), so a hostile `balanceOf` can
  no longer eat 63/64 of the caller's gas. Every other token view read is capped at
  `VIEW_GAS_CAP` (100k). Balance DELTAS are never guessed: on the accrual and epoch-pull
  paths an unreadable `before` skips the mint/pull and an unreadable `after` books
  nothing (arrivals stay unbooked); `fundStream`, `notifyReward` and deposits revert
  `BalanceReadFailed`. The live-pull and epoch-pull fee transfers no longer revert: on
  failure no fee is taken, the amount stays with stakers, and `FeeTransferFailed` fires.
- **MintRights (M-03, L-03)**: rights bound rate INCREASES only — a MINT rate decrease is
  never blocked, even after rights are narrowed below the aggregate. Resuming a MINT
  stream is Owner-only (its manager can still stop it). `setMintRights` cancels any
  pending schedule (`MintRightsScheduleCancelled`); a matured schedule must be applied
  within `MINT_RIGHTS_WINDOW` (14 days — extended from 7 for two-round timelock
  execution, see "Timelock governance") or it reverts `ScheduleExpired`.
- **Stream replacement (L-01)**: the residual sweep is non-reverting (principal-fenced,
  gas-bounded); a dead token's slot is recycled and an unsendable residual is booked for a
  later `sweepResidual` (see the review follow-ups).
  `StreamReplaced.residualSwept` reports what actually moved.
- **PULL source terms (L-02)**: `setPullTerms(pid, index, maxFeeBps, maxPerSec, maxWindow)`
  — set by the stream's source, per stream; a stream without terms draws nothing. A live pull whose stream fee
  exceeds the ceiling is skipped (the interval is forfeited, silently); an
  epoch start reverts `FeeTooHigh`. Existing fee'd PULL streams stop drawing until their
  source opts in. See "Distributor: review follow-ups" for the pace bound and fee credit.
- **Epoch scheduling (R01-R03)**: `setStreamEpochMinBudget` (owner/manager) gates every
  automatic or permissionless start (funding, penalty inflow, config auto-start, anyone's
  `startStreamEpoch` → `BudgetBelowMinimum`); Owner, Admin and the manager may start any
  non-empty budget. The default (0) DISABLES permissionless and automatic starts — only
  an operator start, or operator funding, opens a period until a minimum is set. A length set during a running period is queued
  (`StreamEpochLengthQueued`, `streamEpochConfig`) and applied at the next start instead
  of reverting `EpochInProgress`. The display `ratePerSec` saturates at uint128 instead of
  reverting the start.
- **Rounding and recovery (R04)**: new reward debt rounds UP (pending still rounds down,
  clamped at 0), so the sum of payouts never exceeds what was debited from a reserve.
  `recoverStreamReserve` is clamped to `balance - totalStakedOf[token]`: it can no longer
  revert on drift or take staked principal.
- **Gas**: `UserInfo` packs into one slot (`uint192 amount`, SafeCastLib-bounded); the
  redundant stale-generation debt write is gone; the epoch length is mirrored in the
  Stream slot (`Stream.epochLength`) so non-epoch streams skip a cold `streamEpochs` read
  on every accrual. Net effect with all fixes: -12.5k gas on a paying 2-stream hook
  transfer, -21k on a first deposit, -5.5k on a harvest.
- **API**: new `setPullTerms`, `setStreamEpochMinBudget`, `sweepResidual`,
  `unsweptResidual`, `streamEpochConfig`, `MINT_RIGHTS_WINDOW`, `VIEW_GAS_CAP`, events
  `StreamEpochLengthQueued`, `StreamEpochMinBudgetSet`, `PullTermsSet`,
  `FeeTransferFailed`, `MintRightsScheduleCancelled`,
  `ResidualSwept`, errors `BudgetBelowMinimum`, `ScheduleExpired`, `BalanceReadFailed`.
  `Stream` (and so `streamInfo`) gains `epochLength`, `pullMaxFeeBps`, `pullMaxPerSec`,
  `pullMaxWindow`, `pullFeeCredit`, `pullFeePaid` and `pullNet`. `streamEpochs` is unchanged.

## Distributor under EIP-170 (linked `DistributorLogic`)

`Distributor` was 25,958 B of runtime code at `37e8512` and 29,052 B with the audit fixes —
over the 24,576 B EIP-170 limit, so undeployable on Base (`forge test` does not enforce the
limit). Cold paths now live in `src/farm/DistributorLogic.sol`:

- `library DistributorLogic` (external, DELEGATECALLed; storage stays in Distributor and is
  passed by reference): `addPool`, `addStream`, `replaceStream`, the MintRights
  schedule/apply/set trio, `setStreamEpochLength`, epoch starts incl. the PULL budget draw,
  `recoverStreamReserve`, and the `pendingTokens` / `poolRewardsPerSec` / `streamInfo` views
  (encoded in the library, returned verbatim). Authorization, `_updatePool`, and every
  deposit / withdraw / hook / harvest / settle path stay inline in Distributor.
- `library DistributorIO` (internal): the token-read, payout and emission helpers shared by
  both, so there is one source for each.

Result: Distributor 23,768 B runtime (808 B EIP-170 margin), DistributorLogic 10,133 B. Hot
paths are unchanged (-69 to -466 gas); moved cold paths cost +3.1k to +5.3k gas each (the
library call). The ABI, events, errors, and storage layout are unchanged. **Deployment:**
DistributorLogic is deployed once and linked into Distributor's bytecode; `forge script`
and `forge test` do this automatically (the Deploy broadcast gains one library-deploy
transaction). `script/ci/check-sizes.sh` now fails CI if any deployable `src/` contract
exceeds 24,576 B runtime or 49,152 B initcode.

## Audit fixes outside the Distributor (post-`37e8512`)

Fixes for the audit round against `41a3485` + `37e8512` (regressions
in `test/EscrowStakingAuditFixes.t.sol`, `test/FeeAuditFixes.t.sol`,
`test/OraclePolWrapperRegression.t.sol`, `test/BoundedTransferRegression.t.sol`).

### Staking / escrow / LoC

- **Staking replacement cannot be blocked or trapped**: `syncShares` only counts an escrow
  whose `staking()` is this instance (`EscrowNotWired` if neither is), so nobody can
  pre-fill a replacement before it is wired, and the gap between the two `setStaking`
  calls cannot double-count a conversion. `_maybePullRebase` does nothing while
  `totalShares == 0`, which closes the same pre-fill through a permissionless `claim()`.
  An escrow moving off an instance whose migration is still pending now ABANDONS that
  migration (`MigrationAborted`; queued rewards return to the Owner) instead of reverting
  — one wrong `setStaking` used to trap the escrow permanently.
- **Conversion respects exemptions**: `convertTo` reverts `ExemptConversion` when the
  sender is hook-exempt on the source but not on the destination.
- **LoC interest**: the default interest sink is stored as `address(0)` and resolved to
  the factory's `stakingContract` at every flush, so it follows a staking replacement;
  `interestSink()` returns the resolved address and `setLoCInterestSink(loc, address(0))`
  restores the default. Interest to the live staking contract mints without a rebase; any
  other sink mints WITH one (escrow holders are otherwise diluted with no compensation).
  `ILoCFactory` gains `stakingContract()`.
- **Bounded transfer**: `_tryTransfer` is scratch-space assembly with SafeTransferLib's
  success rule, including the code-existence check on an empty return.

### Fee subsystem

- **FeeConverter follows a staking replacement**: `staking` is settable, but only to an
  instance BOTH escrows of the current one already point at, so the Owner key alone cannot
  redirect ALB / WETH. Streaming to a deprecated instance reverts `StakingDeprecated`; the
  burn legs are not held up by it. `releaseBurnBudget` returns earmarked WETH to the
  streamed pool when a buyback cannot run. Swap value math is checked.
- **BunniFeeDistributor**: `renounceOwnership` is disabled. Both fee contracts use the
  transient reentrancy guard. The failing fixture is fixed (it passed a codeless ALB).
  The contract is still NOT READY: its LP push targets `notifyReward`, which the
  Distributor rejects for non-hook tokens, so every LP share is deferred.

### Oracle / POL / wrapper

- **AlbPriceOracle**: after a gap purge shorter than the window, the newest pre-gap sample
  is the clamp anchor for the first fresh write (it used to be the raw read). After such a
  purge `safeSpotPrice`'s 10x band is still based on the old price until the ramp catches
  up; `setTwapSource(twap, true)` is the fast recovery.
- **BunniWrapperVault**: `harvest` skips a gauge reward token equal to the LP token, the
  gauge or the vault instead of reverting; `setGaugeMinter` validates the primary token.
- **POLHolder**: a stable or retired asset with a PRICED balance worth at most one oracle
  unit (~$1) can be delisted; an unpriceable one still needs a zero balance. The harvest
  leg prices only the entries it values and reads each reward price once per call
  (-50% to -70% gas on a harvest-only `maintain`).

### Low-level calls

Every fixed-size low-level call in `src/` builds its calldata in scratch space and copies
at most one return word (`_tryTransfer`, the rebase pull, the POL allowance read, the
oracle's decimals read, the Distributor's bounded reads). `abi.encode` remains only where
dynamic data is hashed.

### Distributor: review follow-ups

- **Epoch budget bound**: one period books at most `uint128.max` per second. An oversized
  reserve no longer blocks the start and no longer overflows accrual (which bricked the
  pool with a reward token of absurd supply); the excess stays queued in the reserve.
- **`ACC_PRECISION` is 1e27** (was 1e18): a low-decimals reward (USDC, cbBTC) against an
  18-decimals stake credited nothing on small accruals, so frequent `updatePool` calls
  could zero the emission.
- **Unsent replacement residual**: a `replaceStream` sweep that does not go through is
  booked in `unsweptResidual[token]` and retried with `sweepResidual(token, to, amount)`
  (Owner), in parts if the token limits transfers.
  Regressions: `test/DistributorReviewFixes.t.sol`.
- **PULL terms are per stream**: the fee ceiling is keyed to one stream incarnation, so a
  fee accepted on one stream cannot be applied to another stream of the same source.
- **A blocked draw cannot open a period**: an epoch start whose fee is above the source's
  ceiling reverts instead of skipping the draw and starting a full period on leftovers.
- **Source pace and window, fail-closed**: `maxPerSec` caps live pulls, and each period
  draws at most `maxPerSec x min(maxWindow, length)`, so neither a short nor a long
  manager-chosen period can commit a standing allowance at once. A pace of 0 draws
  nothing: **a PULL stream draws only after its source set terms for that incarnation**.
  `type(uint128).max` / `type(uint32).max` are the explicit "no bound".
- **Fee credit**: reserve returned to a PULL source carries back, pro rata, the fee VALUE
  that was paid on it, and later pull fees are set against that credit. Recover-and-repull
  cycles cannot move a source's funds into fees, and no fee change inflates or burns it.
- `setStreamEpochLength` now accrues the pool before QUEUEING a length as well (it already
  did before applying one); the queued value and event are unchanged.
- **Accrual never books more than it asked for**: the balance delta of a live MINT / PULL
  accrual and of an epoch pull is clamped to the amount requested. A reward token that
  overstates its balance used to overflow the accrual and freeze the pool, every stop
  lever included.
- **Accrual-side calls are gas-capped**: a reward token's `mint` / `transferFrom` during
  accrual and epoch draws gets `REALISE_GAS_CAP` (300k) instead of all gas, so a
  gas-burning token costs a bounded stipend per stream on hook transfers, withdrawals and
  the stop levers. A token whose honest mint / transferFrom needs more than 300k (less for
  tokens behind proxies, which keep 1/64 per frame) cannot be a MINT / PULL reward.
- **A starved call reverts instead of forfeiting**: a capped `mint` / `transferFrom` (and
  the staking contract's capped auto-claim transfer) that fails while less than the whole
  stipend was on offer reverts the transaction. Tokens with nested call frames hand gas
  back, so an under-supplied `updatePool` could otherwise fail an honest token's call,
  complete, and forfeit the interval. Side effect: while a live token fails for its own
  reasons, accrual paths need a gas LIMIT of roughly 350-400k (gas used is unchanged).
- **Fee changes accrue first**: `setStreamFundFee` settles the pool at the old fee.
- **Views follow the source's terms and the fee**: `pendingTokens` / `poolRewardsPerSec`
  project a live PULL stream at the slower of the manager's rate and the source's pace,
  net of the funding fee, and at zero when the fee is above the source's ceiling. Accrual
  uses the same figure, so a blocked stream is silent (no shortfall log, no draw).
- The farm itself is rejected as the recipient of a replacement residual or a sweep.
- A surplus arrival (more than was asked for) and an arrival behind an unreadable balance
  stay in the farm as unbooked balance; the farm has no exit for unbooked balance.
- **Residual book holds only unsent balance**: `replaceStream` claims at most what the farm
  holds net of what is already booked, so a balance that went missing is not booked, the
  same balance is never booked twice, and the book cannot later be paid out of another
  stream's backing; `sweepResidual` clamps the book to the farm's free balance before
  every sweep, so balance that went missing later is written off. Sweep a booked residual
  before funding another stream of that token (the farm keeps no per-token aggregate).
- `setStreamFundFee` is `nonReentrant`.

## Action permissions and wrapper coverage (post-audit-fixes)

- **`ActionPermissions`** (`src/utils/ActionPermissions.sol`, shared by POLHolder,
  POLHolderRareLegs and FeeConverter): the static `_forbiddenSelector` blacklist is
  replaced by an Owner-set ALLOWLIST per `(target, selector)`, with the approval
  spender bound into the permission. Permissions pin the target's (and spender's)
  codehash — a code change invalidates them (`ActionCodeChanged`) — and carry an
  epoch per address: un-whitelisting a swap target bumps its epoch, bulk-invalidating
  every permission that references it. Granting requires the target (and spender) to
  already be whitelisted. Executors deploy with NO permissions: operators can execute
  nothing until the Owner allows each selector. Regressions:
  `test/ActionPermissions.t.sol`.
- **BunniWrapperVault test coverage**: `test/BunniWrapperVault.t.sol` (harvest paths,
  gauge minter wiring, reward-token skips) and `test/POLLoopGas.t.sol` (POL loop gas
  characterization).
- The Foundry boilerplate README was replaced with a project README indexing the
  docs; the stale `README copy.md` legacy note was folded into it.

## Admin-level pool creation (post-light-deploy)

`addPool` dropped from Owner to Owner-or-Admin: with unlimited pools the audit's gas
argument is gone, an empty pool earns nothing (every value path — MintRights, PULL
binding and source terms, funded reserves — keeps its own gate), and HOOK registration
still requires the token's `distributor()` opt-in. The one formerly-irreversible side
effect is now curable: `clearDepositRegistration(token)` (Owner, only at zero
custodied stake) clears the DEPOSIT-stake mark so a retired stake token can later
become a HOOK token. Community farms — venue, streams, funding, epochs — now run
entirely at Admin/manager/permissionless speed. Regressions updated in
`ProtocolNotesRegression` and the DeployLight proof suite; new coverage in
`DistributorManager.t.sol`.

## GovALB per-wallet cap

`EscrowedToken.walletCap` (owner-set `setWalletCap`, zero disables — esALB stays
uncapped): every acquisition path (deposit, conversion, transfer-in) reverts
`WalletCapExceeded` when the recipient's POSITION — balance plus vesting custody,
so parking tokens in `startUnstake` cannot dodge it — would exceed the cap.
Hook-exempt custodians are outside it; enforcement is prospective-only (lowering
never confiscates; reductions always allowed). Wired in DeployLight via the
required, validated `GOVALB_WALLET_CAP` (5M in the env). Regressions in
`EscrowConvertAndRevive.t.sol` and the DeployLight proof suite.

## Timelock governance (light deploy)

The Distributor is timelock-owned like everything else. (An ops-multisig-ownership
exception was briefly adopted, then dropped: the DAO timelock's 7-day minDelay meant
its `alb.revokeMinter(farm)` backstop could never catch a rogue 2-day MintRights
schedule, so the exception's safety story did not hold.) Three changes make a 7-day
minDelay workable instead:

- **`MINT_RIGHTS_WINDOW` 7 → 14 days**: a rights increase is two timelock rounds
  (`scheduleMintRights`, then `applyMintRights` after the 2-day internal delay); the
  wider window lets the second round be scheduled after the first executes and still
  land ~9 days before expiry, fully serially.
- **`cancelMintRights` (new, Owner-or-Admin)**: kills a pending schedule instantly.
  Cancelling only narrows, so it fits the Admin doctrine — and it is the emergency
  lever a timelock-owned farm otherwise lacks.
- **PULL binding demoted Owner → Admin**: since the per-stream terms fix, a bound
  stream is fail-closed until its SOURCE accepts terms for that exact incarnation —
  the source's acceptance is the real consent, so H-01's attack is dead regardless
  of who binds, and pull-partner onboarding no longer waits 7 days on the timelock.

**Escrow transfer whitelist at admin speed**: `EscrowedToken.setWhitelisted` is
Owner-or-Admin (was Owner-only). Whitelisting cannot move or take balances — worst
case it opens a transfer route, which removal closes — and the load-bearing entries
(the token contract itself and the staking contract) stay removal-guarded. NOTE:
contracts deployed before this change carry the Owner-only version on-chain.

Community-farm velocity is unchanged: the whole operating surface (pools, streams,
rates, fees, epochs, funding) is Admin-level or below; Owner keeps the structural
set (MintRights, `replaceStream`, sweeps/recovery, `setFeeRecipient`,
`clearDepositRegistration`). The timelock also keeps `alb.revokeMinter(farm)` as
defense in depth. A dedicated controller contract can still take farm ownership later.
