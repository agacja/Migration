# Option deadlines during oracle recovery

Option lifetimes now count time only while the oracle's daily SMA history is warm
and fresh. The existing requirement of 20 distinct daily observations is unchanged.

`AlbPriceOracle.optionClock()` stops during initial warm-up, a stale daily history,
and rebuilding after a purge. Staleness begins at the last sample's UTC day bucket
plus three days, matching the daily-history freshness check. The clock resumes
when sampling restores 20 distinct days. Missing a sampling transaction cannot
retroactively add the outage to the option's elapsed lifetime.

Each LoC records a clock offset when it is initialized. An option keeps the duration
between that initialization and its configured expiry, excluding subsequent pauses.
Options created during recovery receive their full configured lifetime. The clock is
monotonic, so an option that already expired cannot become redeemable after an outage.
An expiry of zero still means no deadline.

Frontends should display `LoC.effectiveOptionExpiry(index)`. The existing
`options(index).expiry` field remains the original configured value. While the clock
is paused, the effective wall-clock deadline moves forward with time.

Redemption still requires a healthy live TWAP and an SMA at or above the strike. The
redemption call may write the final daily recovery sample itself. Brief live-feed
failures while the daily SMA history remains fresh do not pause this clock: the
underlying feed can be updated independently, so its current timestamp cannot prove
how long a past outage lasted.

These interfaces must be deployed together. This source change does not update
already deployed oracle contracts or existing LoC clones.
