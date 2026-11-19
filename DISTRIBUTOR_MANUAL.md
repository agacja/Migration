# Distributor usage manual

Operational guide for `src/farm/Distributor.sol` after the farm-management rework
(per-stream managers, PULL epochs, stream replacement, MintRights, per-stream fees,
unbounded pools). Companion to `FIXED_EMISSION_PERIODS.md`, which specifies the epoch
emission math.

## The model in one paragraph

Pools hold stake (DEPOSIT pools custody tokens; HOOK pools mirror wallet balances of an
opted-in token). Each pool carries up to 8 reward **streams**; a stream is one reward
token plus an emission source: **MINT** (fresh supply, bounded by per-token MintRights),
**PULL** (drawn from a consenting source's allowance), or **BALANCE** (pre-funded
reserve). Emission is either a manual `ratePerSec` or **epoch mode**: a fixed period
length whose rate is derived from the funded budget each period. Accrual is lazy —
state advances when someone touches the pool. Harvests are locked for a fixed
30-second interval. Every stream may carry a funding fee (skimmed to `feeRecipient`)
and an operational **manager**.

## Deployment

Distributor is split in two to fit the EIP-170 code-size limit: `Distributor` (all storage,
authorization and every hot path) and the external library `DistributorLogic` (cold admin,
configuration and view paths, DELEGATECALLed with references into Distributor's storage).
The library is deployed once and linked into Distributor's bytecode — `forge script` does
this automatically, adding one library-deploy transaction to the broadcast. The library has
no state and no access control of its own: called directly (not via Distributor) it can only
touch its own empty storage, and its state-changing functions refuse a plain CALL.
`script/ci/check-sizes.sh` keeps every deployable `src/` contract under the limits.

## Who can do what

| Action | Owner | Admin | Stream manager | Anyone |
|---|---|---|---|---|
| addPool | ✓ | ✓ | | |
| clearDepositRegistration | ✓ | | | |
| addStream — MINT / BALANCE | ✓ | ✓ | | |
| addStream — PULL (binds a consented source; inert until it sets terms) | ✓ | ✓ | | |
| replaceStream | ✓ | | | |
| setStreamRate — BALANCE | ✓ | lower only | ✓ (own) | |
| setStreamRate — PULL | ✓ | | ✓ (own) | |
| setStreamRate — MINT (≤ MintRights) | ✓ | ✓ | | |
| setStreamEpochLength / setStreamEpochPull / setStreamEpochMinBudget | ✓ | | ✓ (own) | |
| setStreamActive — stop | ✓ | ✓ | ✓ (own) | |
| setStreamActive — resume BALANCE / PULL | ✓ | | ✓ (own) | |
| setStreamActive — resume MINT | ✓ | | | |
| recoverStreamReserve (PULL: always back to the source) | ✓ | | ✓ (own) | |
| setStreamFundFee (≤ 20%) | ✓ | ✓ | | |
| setStreamManager | ✓ | | ✓ (own, handover) | |
| MintRights: schedule / apply (within 14 days of maturity) / lower | ✓ | | | |
| cancelMintRights (kill a pending schedule) | ✓ | ✓ | | |
| setIntermediary — flag / unflag | ✓ / ✓ | ✓ / | | |
| setDepositsPaused — pause / resume | ✓ / ✓ | ✓ / | | |
| setFeeRecipient | ✓ | | | |
| fundStream (BALANCE only) | | | | ✓ |
| startStreamEpoch — budget ≥ minBudget | | | | ✓ |
| startStreamEpoch — any budget | ✓ | ✓ | ✓ (own) | |
| updatePool, syncStake | | | | ✓ |
| setPullSource / setPullTerms (your own streams) | | | | ✓ |

The standing rule: **Admin may only stop or narrow**; everything that creates or
redirects value is Owner — except where a manager spends their own stream's budget, or
where MintRights already bound the damage. Binding a stream to a PULL source is Admin-level
because binding alone moves nothing: a bound stream is fail-closed until the SOURCE accepts
terms for that exact incarnation (`setPullTerms`) — the per-stream acceptance is the real
consent. A PULL stream's recovered reserve always returns to its source, so no manager or
Admin ever chooses where a source's funds go. `cancelMintRights` is the other Admin
carve-out: cancelling only narrows, and it is the instant lever against a bad schedule.

## Owner

The farm's Owner is the DAO TIMELOCK, like every other contract in the system. Every
"Owner" row above is therefore a schedule → minDelay → execute round on the timelock;
the Owner surface is deliberately the rare structural set, and everything with
day-to-day cadence sits at Admin level or below. MintRights is the one Owner flow
with an internal clock on top — see the first "Do" below; its apply window (14 days)
is sized so two timelock rounds at a 7-day minDelay fit even run serially.

**Do**
- Grant MintRights before expecting any MINT stream to emit: `scheduleMintRights` →
  wait `MINT_RIGHTS_DELAY` (2 days) → `applyMintRights` within `MINT_RIGHTS_WINDOW`
  (14 days) of maturing, or the schedule expires and must be re-scheduled. Under the
  timelock that is two rounds; schedule the second as soon as the first executes.
  Lowering is instant via `setMintRights` and cancels any pending scheduled increase;
  the Admin can also `cancelMintRights` a pending schedule with no delay. Rights are a per-token **aggregate** across all MINT streams of that
  token; the token must also grant this contract its minter role.
- Treat `replaceStream` as the slot-recycling tool for **dead or announced** streams.
  It sweeps the old token's unaccrued reserve **and earned-but-unclaimed rewards** to
  `residualTo`, and voids stakers' stale debt/lockups. Announce it; stakers who don't
  harvest first lose their unclaimed rewards of the old token to the sweep.
- Whoever creates a HOOK pool (Owner or Admin) must verify the stake token's
  integration before `addPool`: it must expose
  `distributor()` returning this farm, and call `notifyStake`/`notifyUnstake` exactly
  once per transfer, **after** its balances settle, with nothing user-controlled
  interleaved. A token that notifies before balance finalization enables a
  sync-then-notify double count.
- Use `massUpdatePools(start, end)` in chunks if a full sweep is ever needed; the
  no-arg version will eventually out-of-gas as pools grow (harmless — it just reverts).

**Don't**
- Don't register a token as a reward stream if it might ever need to be a HOOK stake
  token: `isRewardToken` is permanent, even after replacement.
- Don't use `replaceStream` to "end a stream early but keep stakers whole" — that's
  `recoverStreamReserve`'s job (it can't touch earned rewards; replacement can).
- Don't expect lowering MintRights to stop an already-configured rate — rights bound
  rate **increases** when rates are set. To halt emission now: `setStreamActive(false)`
  (Admin can); rates can always be lowered afterwards, even below-rights narrowing never
  blocks a decrease. Only the Owner resumes a MINT stream (its manager cannot).

## Admin (ops multisig)

**Do**
- Open community-farm venues yourself: `addPool` is Admin-level for both kinds. An
  empty pool earns nothing — every value path keeps its own gate (MintRights, PULL
  binding and source terms, funded reserves) — and HOOK pools still require the
  token's own `distributor()` opt-in. One mark to respect: registering a token as a
  DEPOSIT stake blocks it from ever being a HOOK token until the Owner runs
  `clearDepositRegistration` (possible only at zero custodied stake), so don't open
  DEPOSIT pools for tokens that are destined to become hook tokens.
- Stop things freely: deactivate streams, pause deposits, flag intermediaries, lower
  BALANCE rates. Resuming, unpausing, and unflagging wait for the Owner.
- Add MINT and BALANCE streams for partners (they start inert at rate 0) and set their
  manager and fee at creation — PULL streams are the Owner's call; adjust fees later with `setStreamFundFee` (≤ 20%, proceeds only ever go
  to the Owner-set `feeRecipient`).
- Operate MINT rates freely **within** a token's MintRights.

**Don't**
- Don't front-run funders with fee raises — serious funders use the
  `fundStream(..., maxFeeBps)` overload and their transaction will bounce, and PULL
  sources' own fee ceilings make a raised-fee pull a skipped pull; it burns trust for zero
  revenue.
- Don't flag an address as intermediary casually: flagging strips its hook stake and
  its forfeited future rewards are redistributed; only the Owner can unflag, and the
  missed accrual is not recoverable.

## Stream manager (partner ops)

**Do**
- Set a **minimum budget** before enabling epochs:
  `setStreamEpochMinBudget(pid, index, amount)`. Below it, fundings (and escrow penalty
  inflows) queue instead of starting a period, and anyone's `startStreamEpoch` reverts
  `BudgetBelowMinimum` — so nobody can open a full-length period with a 1-wei budget and
  make your real funding wait a whole period. You, the Owner and the Admin can still
  start any non-empty budget explicitly. The default (0) disables public starts: other
  funders and escrow penalty inflows queue until an operator starts the period. Operator
  funding can start a zero-minimum period; configuring its length alone cannot.
- Prefer **epoch mode**: `setStreamEpochLength(pid, index, length)` once. For BALANCE,
  fund whenever; mid-period top-ups queue for the next period. For PULL, set
  `setStreamEpochPull` to your per-period budget and have your source grant one
  standing allowance — each period then draws only its budget, no re-approvals.
- End a stream early with `recoverStreamReserve(pid, index, to, type(uint256).max)`
  (clamped to the farm's free balance of the token — held minus DEPOSIT principal — so
  it can never reach staked principal or revert on rounding drift):
  - manual-rate: recovers everything unaccrued and terminates emission on the spot;
  - epoch mode: the running period's unvested remainder stays committed — recover the
    queued/leftover part now and the rest after the period's calendar end (pausing
    stops emission immediately, but the wall-clock guard releases the paused span's
    tokens only once the period's end passes).
- Hand over managership with `setStreamManager` when your ops key rotates; the old key
  loses all powers instantly.

**Don't**
- Don't set the epoch length equal to your funding cadence: a funding that lands
  minutes *before* the period ends queues for the next period, which then won't start
  until your following funding — a full period of dead air. Make the epoch slightly
  shorter than the cadence, or pair funding with a (harmless, permissionless)
  `startStreamEpoch` call after expiry (public starts require a positive minimum budget).
- Change the period length whenever you like: during a running period the new length
  is queued (`StreamEpochLengthQueued`) and applied at the next start, whoever triggers
  it — set it before the current period ends so a permissionless start cannot beat you.
  The running period itself cannot be restarted, and manual rates stay locked in epoch
  mode (`EpochRateIsDerived`); there's no way back to manual rates short of an Owner
  `replaceStream`.
- Recovering from a PULL stream always pays the stream's source; the `to` argument is
  ignored for PULL.
- Don't expect a say in your stream's fee — it's the protocol's side of the deal.

## PULL source (partner treasury)

**Do**
- Consent explicitly with `setPullSource(true)`; your allowance to the farm is the
  hard cap on everything it can ever take. Revoking consent (or zeroing the
  allowance) stops draws at the next accrual/period.
- **Set your terms on each stream bound to you**: `setPullTerms(pid, index, maxFeeBps,
  maxPerSec, maxWindow)`. Until you do, that stream draws **nothing**: an allowance alone
  is not consent to a stream. Terms belong to one stream, so accepting them on one never
  exposes another, and a replaced stream starts without terms again (your allowance
  survives a replacement; your terms deliberately do not).
  - `maxFeeBps` is the highest funding fee you accept (0 = fee-free pulls only). A stream
    whose fee is above it cannot draw from you: live pulls forfeit that interval, an
    epoch start reverts `FeeTooHigh`. An Admin fee raise above your ceiling can never be
    applied to your funds.
  - `maxPerSec` is the pace in tokens per second, on live pulls and per period on epoch
    pulls. 0 draws nothing; `type(uint128).max` is the explicit "no bound".
  - `maxWindow` is the most seconds of pace one period may draw up front, whatever
    length the manager chooses. What a period has drawn is committed to stakers and you
    cannot take it back, so pick a window you are comfortable losing the ability to
    revoke: a manager who also stakes receives most of what is drawn.
- Reserve that a manager returns to you (`recoverStreamReserve`) brings back the fee
  value you paid on it as a credit against the fee of later pulls.
- **To stop one stream, zero its terms**: `setPullTerms(pid, index, 0, 0, 0)`. It settles
  the stream first, and nothing can be drawn for as long as it stays zeroed. Revoking
  consent or the allowance stops draws too, but an interval that nobody accrued while
  it was revoked is drawn, at your pace, once you consent again.
- For epoch streams: grant one standing allowance; the manager's `pullAmount` and
  your own `maxPerSec x maxWindow` both meter each period's draw (the tighter bound
  wins). Your `maxFeeBps` ceiling enforces the fee you accepted automatically — fee
  changes are announced by `StreamFundFeeSet`, and a raise above your ceiling simply
  stops draws rather than charging you.

**Don't**
- Don't run a live (manual-rate) PULL stream dry: elapsed emission that can't be
  pulled is **forfeited**, not queued. Epoch mode converts that risk into "the next
  period starts late," which is usually what you want.
- Don't grant allowance to a stream whose manager you don't trust: the manager
  controls the pace (rate, epoch length, pull budget) at which your allowance is
  spent — never the destination (recovered PULL reserve always returns to you), but the
  timing is theirs. Only the Owner can bind a new stream to your source.

## Funders (anyone topping up a BALANCE stream)

- `fundStream` is permissionless and measured on arrival (fee-on-transfer safe). Use
  the `fundStream(pid, index, amount, maxFeeBps)` overload to pin the fee you accept.
- Funding is a gift to the stream's program: the **manager** can recover unaccrued
  reserve, including your top-up. Fund streams whose managers you trust.
- PULL streams cannot be funded directly — transfer to the stream's source instead;
  the next epoch pull picks it up under the same allowance/fee rules.

## Stakers and integrators

- Harvests are locked for 30 seconds after your previous settle — immediate
  re-harvests bank into `rewardLockedUp` and pay on the next eligible settle.
- `emergencyWithdraw` returns principal only and forfeits all pending rewards. On a
  HOOK pool it only zeroes your tracked position (tokens are already in your wallet) —
  and note that **anyone** can re-enroll you afterwards via the permissionless
  `syncStake`, so it is not an opt-out from tracking.
- `pendingTokens` is an upper bound for MINT/PULL streams (it projects the rate; the
  real update may realize less) and includes locked-up amounts, like the legacy view.
- After a stream replacement, unclaimed rewards of the old token are gone (swept to
  the replacement's `residualTo`); your view and settlement automatically start clean
  on the new token. Harvest when a replacement is announced.
- Sending tokens straight to the farm does nothing good: donations don't dilute
  (accounting is tracked, not balance-based) but they aren't credited to you either.

## Farm-bound EscrowedTokens

A dedicated EscrowedToken can use a Distributor as its hook consumer instead of the
StakingContract: `setStaking(farm)`. The farm exposes IStakingContract-shaped aliases
(`notifyDeposit`/`notifyWithdraw`/`notifyReward`), probes the escrow's `distributor()`
for the HOOK opt-in, and `syncStake` reads `stakedSharesOf` (not raw balance), so
vesting partial power survives third-party syncs. `syncStake` also honours the escrow's
`isHookExempt`: exempt accounts (the escrow's own vesting custody, its consumer, any
exempted custodian) read as zero stake, so a third party can never enroll them.

- **Wiring order**: deploy escrow → `setStaking(farm)` → `addPool(escrow, HOOK)` →
  streams → open deposits. Between `setStaking` and `addPool` the token is inert
  (hooks revert), which is fine — nothing can mint yet.
- **Penalties**: by default `finalizeUnstake` redistributes the penalty through
  `notifyReward` into the pool's matching BALANCE stream of the underlying, which must
  therefore be registered before the escrow opens. **If the underlying is (or may ever
  be) a hook token, set `penaltySink` instead** — hook tokens cannot be reward streams,
  so the redistribution path would brick every early exit; the sink routes penalties by
  plain transfer to a treasury address, and no penalty stream is needed at all.
- **No consumer hot-swap**: replacing a farm-bound escrow's consumer invokes the
  staking-migration lifecycle the farm doesn't implement; rebinding means a new escrow.
- **Streams on escrow hook pools should be reserve-backed** (BALANCE, or PULL in epoch
  mode): a live PULL stream would run its source `transferFrom` inside every escrow
  transfer.
- If the escrow's underlying is a hook token, flag the escrow contract as an
  intermediary in the underlying's pool — its backing custody must not earn there.

## Sharp edges, all in one place

0. **A hook token MUST let a reverting notification revert its transfer.** Never wrap
   `notifyStake` / `notifyUnstake` / `notifyDeposit` / `notifyWithdraw` in try/catch or
   in a low-level call whose failure is ignored. While a live MINT/PULL stream's token
   is failing, a notification sent with less than about 360k gas reverts by design (so
   that an under-gassed call cannot forfeit an interval); a token that swallows that
   revert lets a holder move tokens without moving stake. Reject such a token at
   `addPool`. The gas-limit requirement (about 330k, plus about 23k per further failing
   stream) recurs on every accrual of the pool until the stream is stopped with
   `setStreamActive(false)`.

1. **Replacement forfeits unclaimed old-token rewards** to `residualTo`. Owner-only,
   announce-first, dead-streams-preferably. The sweep never reverts and the slot is
   recycled either way (`StreamReplaced.residualSwept` reports what moved). A residual the
   farm holds but could not send is booked in `unsweptResidual[token]` and retried with
   `sweepResidual(token, to, amount)`, in parts if the token limits transfers. A balance
   the farm no longer holds is not booked, and is written off at the next sweep if it
   goes missing later. The farm does not track what backs each token's other streams,
   so **sweep a booked residual before funding another stream of that token**: a later
   sweep is paid from whatever the farm holds. For the same reason, when several
   streams share a token whose balance has shrunk, the replaced stream is paid first.
2. **Epoch ≠ funding cadence** — see the manager section; the queue-miss gap is the
   one real scheduling footgun. Set `minBudget` so a dust funding cannot open a
   near-empty period ahead of the real one.
3. **Live PULL forfeits on dry sources**; epoch PULL just starts late.
4. **`isRewardToken` is forever** — a reward token can never become a HOOK stake.
5. **Epoch mode is one-way** per slot (until replaced).
6. **MintRights bind rate increases at rate-set time**, not continuously — pause first
   in an emergency, then lower (a decrease is never blocked, even after rights were
   narrowed below the running aggregate). Only the Owner resumes a MINT stream.
7. **The 8-stream cap is per pool and slots never disappear** — but `replaceStream`
   recycles them.
8. **Hook tokens are trusted integrations**: hooks after balance settlement, exactly
   once per transfer, no interleaved callbacks. `syncStake` heals drift for accounts
   (and reads a token's `isHookExempt` accounts as zero stake);
   `setIntermediary` is the only cure for balances parked at contracts that must not
   earn (routers, pairs — and the farm itself is implicitly one).
9. **Payout gas is two-tier**: inside hook transfers, intermediary strips, and
   third-party syncs, reward-token calls are capped at 150k gas (a heavyweight token
   defers instead of making the stake token untransferable); explicit harvests
   (`deposit(pid, 0)`, `withdraw`, `harvestMany`) forward up to **1M gas**, enough for
   any honest token including reflection-style bookkeeping. Both tiers are finite so a
   hostile gas-burning token costs a bounded stipend and defers — the stipend covers the
   payout's balance read and its transfer together — it can never OOG a
   withdraw. A token that genuinely needs >1M per transfer has no place as a reward
   token.
10. **Fees apply to every funding route**, within a PULL source's own per-stream
    ceiling (`setPullTerms`, default 0) — `fundStream`, epoch pulls, and live pull
    realizations — so the funding mode never changes what a farm owes; on live pulls
    the fee is paid gradually per realization, on epoch pulls up front per budget.
    A pull's fee transfer never reverts the accrual or the period start: if the fee
    cannot be delivered, no fee is taken and the amount stays with the stakers
    (`FeeTransferFailed`).
11. **Token reads are bounded and deltas are never guessed.** Every token view read is
    gas-capped (`VIEW_GAS_CAP`, 100k; payout reads share the payout stipend) and copies
    at most one word. A balance DELTA is only booked when both reads succeed: an
    unreadable balance before a mint/pull skips it, an unreadable balance after it books
    nothing (anything that arrived stays unbooked), and funding/deposit/penalty flows
    revert `BalanceReadFailed` rather than credit a guessed amount.
