# Review 008 — Settlement-phase object-size reduction (gas)

| Field | Value |
| --- | --- |
| **Review #** | 008 |
| **Date** | 2026-06-07 |
| **Type** | Internal optimization + correctness preservation review |
| **Methodology** | Sui gas-model analysis (object rewrite cost) + access-pattern proof + full re-test |
| **Base** | working tree on top of `2a17064` (continues 005/006/007) |
| **Reviewer** | Internal |
| **Tests** | `sui move test` — 87 passed / 0 failed; build warnings unchanged at 3 (pre-existing `PairFeeTierUpdatedEvent`) |

> Immutable snapshot. Current status is tracked in [README.md](README.md).

## Motivation

On Sui, computation is **coarse-bucketed** (no per-instruction metering) and a mutated object is
re-serialized in full, so the dominant, controllable cost for a high-frequency entry point is the
**size of the shared object it mutates**. `settle_intent*` is the hot path: it is invoked once per
winning intent (potentially hundreds of times per epoch) and mutates the shared `AuctionState`.

Before this change, `AuctionState` carried the entire Bid/Selection working set —
`bids: vector<Bid>` (each `Bid` embeds five parallel vectors), `allocations: vector<Allocation>`,
and `pair_benchmarks: VecMap<PairKey, BenchmarkEntry>` (each entry embeds `intents`/`payouts`
vectors) — for the **whole settlement phase**, even though none of it is consumed after a winner is
selected. Every `settle_intent` therefore deserialized and re-serialized that dead weight (worst case
≈ 250 KB under the configured caps), inflating its computation bucket and deferring the storage
rebate until the next epoch rollover.

## Change

In `run_selection` (`sources/auction.move`), once a winner is committed (either the
allocation-winner branch or the benchmark-fallback branch — the abort branch returns earlier), the
three heavy collections are dropped:

```move
capture_benchmark_refs(state);
state.pair_benchmarks = vec_map::empty();
state.bids = vector[];
state.allocations = vector[];
```

`bids` and `allocations` are dropped outright. `pair_benchmarks` is needed once more — at close, by
`reference_score_excluding` — but only for two scalar fields per pair, so a new compact
`committed_benchmark_refs: VecMap<PairKey, BenchmarkRef>` (`BenchmarkRef { auctioneer, total_score }`)
is populated from it first, and the close-path reference now reads that compact map instead of the
full `pair_benchmarks`. `committed_benchmark_refs` is reset per epoch alongside all other transient
state.

Net effect: for the entire settlement phase the shared object retains only the winner/settlement
maps (`winner_*`, `intent_floor`, `committed_k_by_pair`, `solver_*`, reservations,
`committed_benchmark_refs`). Storage for the dropped collections is rebated at selection rather than
at the next epoch.

## Correctness preservation (why this is safe)

**1. The dropped data is provably dead after selection.** Every read of `bids` and `allocations`
occurs in phase ≤ AllocationSelection or inside `run_selection` *before* the clear point
(`submit_bid`, `submit_pair_benchmark`, `validate_allocation`, `allocation_is_valid`,
`commit_winner_from_*`, and the `release_*` reservation helpers). `pair_benchmarks` has the same
read profile plus exactly one post-selection reader, `reference_score_excluding` (close), which is
preserved via `committed_benchmark_refs`. Verified by exhaustive grep of all field usages across
`sources/` and `tests/`.

**2. Reservations are released before the clear.** Both winner branches call their `release_*`
helpers (which iterate `bids`/`allocations`/`pair_benchmarks`) *before* control reaches the clear
block, so no reservation accounting depends on the dropped data afterwards.

**3. The VCG reference is numerically identical.** `committed_benchmark_refs` captures exactly the
two fields `reference_score_excluding` previously read (`auctioneer`, `total_score`), keyed by the
same `PairKey`. The reward computation, the per-solver `β × fee_i` cap, and the conservative
auctioneer-attribution residual documented in review 007 are all unchanged. Reward-amount
assertions (`test_solver_vcg_reward_paid_from_fee_vault` = 30,
`test_competing_allocation_does_not_suppress_reward` = 10_000,
`test_no_solver_reward_when_share_is_zero` = 0) are unchanged.

**4. No new attack surface.** The clear is atomic within the Selection→Settlement transition; it
adds no externally callable entry point and removes no validation. An adversary cannot observe or
act on an intermediate state. The DoS bound (`max_allocations`, review 005) is retained because
`run_selection` still iterates `allocations` *before* clearing them.

**5. Phase invariants intact.** `committed_benchmark_refs` is initialized in `new_state` and reset
in `start_new_epoch` with the rest of the transient state, so it cannot leak across epochs.

## Scope note

This is a representation change only; no mechanism, fee, reward, or floor logic was touched. It does
not address any open finding from 004/005. The previously-discussed migration of per-intent
collections (`intent_meta`, `batch`) to dynamic-field `Table`s was **not** done here: that path
carries a per-epoch drain/reset cost (a non-empty `Table` cannot be dropped by reassignment) that
must be weighed against the per-tx saving, and is deferred to a dedicated review if intent volume
per epoch grows enough to warrant it.

## Methodology

Sui gas-model review (object-rewrite cost dominates for hot shared-object mutators) → access-pattern
proof that the cleared collections are dead post-selection → minimal capture of the one surviving
consumer's inputs → full suite re-run confirming no reward/settlement drift and no new warnings.
