# Fixed emission periods

`Distributor` supports optional fixed-length periods for funded `BALANCE` reward streams.
The owner configures each stream with `setStreamEpochLength(pid, index, seconds)`.
The length must be between one second and 3,650 days. Existing streams retain their
manual-rate behavior until this mode is enabled. `PULL` streams also support periods
funded from their source (see `DISTRIBUTOR_MANUAL.md`); `MINT` streams remain manual-rate.

```solidity
// Owner or manager, for an 18-decimal BALANCE reward token:
distributor.setStreamEpochMinBudget(pid, index, 100 ether);
distributor.setStreamEpochLength(pid, index, 7 days);
// Funder, after approving the reward token:
distributor.fundStream(pid, index, amount);
// After the period ends, any caller can activate queued rewards:
distributor.startStreamEpoch(pid, index);
```

At the start of an epoch:

```text
budget = this stream's unaccrued reward reserve
emission rate = budget / epoch length
end = start + epoch length
```

The budget excludes user deposits, earned but unclaimed rewards, other streams' funds,
and unbooked token donations. Funding uses the actual received amount after transfer
taxes and the funding fee. A 700-token budget over seven days distributes 100 tokens
per day. The stored per-second rate is display-only: it is rounded down to token base
units and saturates at `type(uint128).max` instead of reverting; accrual uses cumulative
proportional amounts of the budget, so fractional rates and the final remainder are
included. Existing per-share rounding still applies when splitting among stakers.

## Funding and subsequent periods

With a positive minimum budget, funding starts a full period when the active stream
has enough reserve. Enabling periods also attempts a start under that minimum, after
settling the previous rate. With the default minimum of zero, public funding queues;
only the owner, Admin or stream manager can start the period. Their own funding can
automatically start it. Configuring the length alone does not start a zero-minimum period.

Funding during a period queues rewards for the next period. It changes neither the
current rate nor its end. Once the period finishes, anyone may call
`startStreamEpoch(pid, index)` to start a full new period using the remaining reserve,
provided a positive minimum is configured and the reserve meets it (below).
Funding after a period ends uses the same start rules and includes the newly
received funds. The next period starts at the transaction time; no rewards
accrue in the gap between periods. No separate service is part of this change.

For example, configure seven days, fund 700 tokens, and fund another 350 tokens on
day three. The first period still distributes 700 tokens by day seven. Starting the
next period distributes the queued 350 tokens over another seven days.

## Administration and edge cases

- The owner or the stream's manager sets the period length (see `DISTRIBUTOR_MANUAL.md`,
  which also covers PULL-stream periods). An unfinished period cannot be restarted, even
  while paused; a length set during it is queued (`StreamEpochLengthQueued`) and applied
  at the next start, whoever triggers it. Manual rate changes are disabled in
  fixed-period mode.
- `setStreamEpochMinBudget(pid, index, amount)` (owner or manager) sets a minimum budget
  for automatic starts and public `startStreamEpoch` calls. A positive value enables
  public starts; below it funding queues and public starts revert `BudgetBelowMinimum`.
  The default 0 disables public starts, including starts through escrow penalty inflows.
  The owner, Admin and manager may explicitly start any non-empty budget. Their funding
  can automatically start a zero-minimum period, but respects a configured positive minimum.
- Pausing stops accrual without extending the end date. Resuming settles no rewards
  for the paused time. An expired or initially unfunded paused stream needs funding or
  `startStreamEpoch` after reactivation to start a new period.
- Rewards scheduled while the pool is empty or the stream is paused remain in reserve
  for a later period; they are not awarded retroactively to a new depositor.
- Reserve recovery can withdraw queued or forfeited rewards, but cannot take rewards
  committed to the rest of the current period or rewards already accrued to users. It is
  also clamped to the contract's free balance of the token (held minus staked
  principal).
- `streamEpochs(pid, index)` exposes the configured length, current start, snapshot
  budget, and PULL draw cap. `streamEpochConfig(pid, index)` exposes a queued length and
  the minimum budget. `streamInfo` exposes the rate, end, remaining reserve, and
  `epochLength` (a mirror of the configured length; 0 in manual-rate mode).
  `pendingTokens` projects the same fractional accrual used when settling rewards.

Validation lives in `test/DistributorEpoch.t.sol`, including fuzzed conservation of
funds across top-ups and rollover, pause and recovery behavior, fees, fractional rates,
principal isolation, and conversion from the legacy rate model; the queued-length,
minimum-budget and saturating-rate behaviour is covered in
`test/DistributorAuditFixes.t.sol`.

Run `forge test --offline --fuzz-seed 0x01 --summary` for the current regression suite.
