# Review 002 — Finding Verification (review 001 follow-up)

| Field | Value |
| --- | --- |
| **Review #** | 002 |
| **Date** | 2026-05-30 |
| **Type** | Internal — test-based verification |
| **Methodology** | Targeted Move tests reproducing each open finding from review 001 |
| **Scope** | All open findings of [001](001-2026-05-30-internal-stride.md) |
| **Commit** | `e72ab0cd896b66d1479e1aacaa7497647f5f5216` |
| **Reviewer** | Internal |

> Immutable snapshot. This review verifies, not fixes. Each 001 finding was reproduced (or refuted)
> with a dedicated test before scheduling any code change. Current status lives in [README.md](README.md).

## Outcome

| 001 Finding | Verdict | Evidence (test in `tests/flow_tests.move`) |
| --- | --- | --- |
| Expired winning intent re-queued / unfair slash | **Confirmed** | `test_expired_winning_intent_take_aborts`, `test_expired_intent_fallback_slashes_solver` |
| Fully-drained partial-fill leaves zombie object | **Confirmed** | `test_zombie_intent_after_full_partial_drain` |
| Overpaid `close_batch` fee not refunded | **Confirmed** | `test_overpaid_fee_absorbed` |
| `update_intent_params` gating | **Reclassified — dead code** | grep: zero callers; no public wrapper exists |
| Unbounded loops gas DoS | **Not verified** | not deterministically unit-testable; remains a reasoned concern |
| `take_intent_partial` multi-take double-count | **Refuted (false positive)** | `test_double_partial_settle_same_intent_reverts` (recorded in 001) |

## Details

### Confirmed — expired winning intent

`drive_one_to_settlement` commits a winner for an intent whose deadline (15_000) precedes the
protocol settlement deadline (43_000). At t=16_000 `take_intent_full` aborts `EIntentExpired`, so the
intent can never be settled. At t=44_000 `trigger_fallback` slashes the assigned solver's **full**
bond (`bond_of` 2 SUI → 0, `slash_count` 1) and moves the epoch to `Failed`, even though the expiry
was outside the solver's control. The intent persists and is re-queued.

Recommendation unchanged: refund expired intents to owner in fallback instead of re-queueing; do not
slash for intents whose deadline preceded the settlement window.

### Confirmed — zombie object

Taking the entire remaining balance through `take_intent_partial` (fill == remaining) drains the
intent to zero but never deletes it. After settlement the `Intent` object is still a live shared
object with `remaining_sell == 0`. Recommendation: when a partial fill empties the balance, route to
the full-consume (delete) path and skip re-queue.

### Confirmed — overpaid fee

With `value_sum = 3135` and `protocol_fee_bps = 5`, required fee = 1, but a 100-unit fee coin is fully
absorbed (`total_collected == 100`). `close_batch` consumes the whole coin with no change returned.

### Reclassified — `update_intent_params` is dead code

No public wrapper calls `intent_book::update_intent_params`; it is `public(package)` with zero
callers. Not currently reachable, so not exploitable. Latent: if an update entry point is added later
it must gate with `can_modify_intent` (as `cancel_intent` does), or the function should be removed.

### Not verified — unbounded loops

`close_batch` / `distribute_rewards` / `trigger_fallback` iterate over committed pairs, winning
solvers, and winning intents. A deterministic gas-limit test was not constructed this round; the
concern stands and a per-allocation size cap is still recommended.

## New tests added

`tests/flow_tests.move`: `test_double_partial_settle_same_intent_reverts`,
`test_expired_winning_intent_take_aborts`, `test_expired_intent_fallback_slashes_solver`,
`test_zombie_intent_after_full_partial_drain`, `test_overpaid_fee_absorbed`,
plus `drive_one_to_settlement` helper. Full suite: 61 tests passing.
