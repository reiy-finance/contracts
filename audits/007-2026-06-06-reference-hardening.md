# Review 007 — Reference hardening (F-005-1) + corrections

| Field | Value |
| --- | --- |
| **Review #** | 007 |
| **Date** | 2026-06-06 |
| **Type** | Internal remediation + correction note |
| **Methodology** | Targeted fix for the last open 005 finding + re-test; trust-model analysis |
| **Base** | working tree on top of `2a17064` (continues 005/006) |
| **Reviewer** | Internal |
| **Tests** | `sui move test` — 87 passed / 0 failed |

> Immutable snapshot. Current status is tracked in [README.md](README.md).

## Scope

Closes the one remaining open finding from review 005, **F-005-1** (reward suppression via an
undeliverable "paper" alternative allocation), and records two corrections to the analysis in 005/006.

## Decision context (trust model)

F-005-1 was initially framed as "Reiy lacks CoW's fairness filtering." On closer analysis that framing
is imprecise (see Correction 1). The accurate root cause is a **trust-model gap**: CoW's VCG reference
also draws on competing (including losing) solver solutions, so CoW's *formula* carries the same
exposure — it is *contained*, not eliminated, by permissioned solvers + bonding pools + persistent
reputation + an off-chain auctioneer with discretion + the social threat of removal. Reiy targets a
more **permissionless / trust-minimized** solver set and currently has a weaker, bypassable reputation
layer (cf. 004 F-004-1, suspend-threshold evasion — still Open), so the same paper-bid trick is cheaper
on Reiy.

Given the project's stated priority (**security ≫ decentralization > performance**) and the intent to
*not* rely on off-chain/social enforcement, the chosen remedy is to make the reference **robust on
chain** rather than to import CoW's social layer.

## [Fixed] F-005-1 — benchmark-only reference

**Change.** `auction::reference_score_excluding` (`sources/auction.move`) now computes the VCG
counterfactual from the **per-pair benchmark only** — the sum of `pair_benchmarks[p].total_score` over
committed pairs whose benchmark auctioneer != the solver. The previous "best competing valid
allocation containing no bids from the solver" term was **removed**. `reference_scores_for` (the
006 batch-precompute helper) and `allocation_contains_solver` were deleted as no longer needed;
`distribute_solver_rewards` calls the per-solver function directly.

**Why this closes the finding.** A losing allocation is an *unbacked claim*: its bid and allocation
stake reservations are **released, not slashed**, at selection, so a rival could submit a valid-on-
paper, never-delivered allocation purely to inflate `referenceScore_i` and suppress the winner's
reward. The benchmark, by contrast, is **load-bearing on chain**:

- it sets the per-intent floor enforced by `allocation_is_valid` (`payout ≥ max(m_eff, benchmark)`), so
  inflating it raises what winners must pay (it cannot be raised "for free"); and
- if the winning allocation fails that floor, the benchmark itself becomes the winner and its proposer
  must deliver it or be slashed in `trigger_fallback`.

So the reference is now anchored to a quantity that already carries on-chain consequence and cannot be
inflated by an undeliverable claim. The griefing vector is removed without any reliance on
off-chain/social enforcement.

**Safety / economics unchanged in the common case.** Where the only allocation containing the winner
*is* the winning one (the typical case), the removed term contributed nothing, so reward amounts are
identical (verified: happy-path reward stays 30, `test_solver_vcg_reward_paid_from_fee_vault` stays
30). Dropping the term can only *lower* the reference, hence only *raise* marginal toward the cap —
never reduce a reward, and never past `β × fee_i`, so the vault remains budget-safe
(`Σ reward ≤ β × Σ fee`). Reference is now O(pairs) per solver.

**Residual (accepted, documented in code).** The benchmark term is attributed by benchmark *auctioneer*,
not by the solver of the underlying benchmark bids; a solver who both provided a benchmark and won has
that benchmark excluded from its own reference → reward slightly *under*-estimated, never over. This is
the safe direction for the vault and is reinforced by the per-solver cap.

**Regression.** `test_competing_allocation_does_not_suppress_reward` (repurposed from the former
`test_reference_uses_competing_allocation_not_just_benchmark`): with a competing valid allocation
scoring 95_000 present, the winner's reward is **10_000** (cap-bound, competing allocation ignored),
not the **5_000** it would have been suppressed to under the old competing-allocation reference.

## Correction 1 — Reiy *does* have a fairness-filter analogue

Review 005 (F-005-1 description) stated *"Reiy has no such filter."* **This is inaccurate.** CoW's
fairness filtering removes solutions that underpay some pair/subset relative to its standalone best.
Reiy enforces the equivalent at validity time: `allocation_is_valid` (`sources/auction.move`) rejects
any allocation in which `payout_i < max(m_eff_i, benchmark_i)` for any intent — i.e. a winning
allocation can never pay any pair below its benchmark. The fairness property CoW achieves via a
filtering stage, Reiy achieves via the per-intent floor check. (Note: this analogue is about *fair
surplus distribution in winners*; it does **not** by itself address F-005-1, which is about
*unbacked reference claims* — that is what the benchmark-only reference addresses.)

## Correction 2 — F-005-2's batch precompute is superseded

Review 006 fixed F-005-2 (per-solver validity recompute in the reward loop) by precomputing allocation
validity once in `reference_scores_for`. The benchmark-only reference removes **all** allocation
iteration from the close/reward path, so that helper was deleted. F-005-2's concern is now resolved
more fundamentally: the reward loop is O(solvers × pairs) with no allocation scan at all. The
`max_allocations` cap is retained because `run_selection` (Selection phase) still iterates allocations.

## Re-verified after change

- Full suite green (87/87). All reward-amount assertions unchanged except the intentionally repurposed
  regression test (5_000 → 10_000).
- No new dead code: `allocation_is_valid` remains live (used by `run_selection`); build warnings
  unchanged at 3 (pre-existing `PairFeeTierUpdatedEvent` unused fields).
- Budget-safety, conservative rounding, no double-distribute, per-epoch state reset — all as
  re-verified in 005/006; unaffected by this change.

## Methodology

Single-finding remediation: the reference computation was reduced to the load-bearing benchmark term,
the now-dead helpers removed, the regression test repurposed to assert the griefing vector is closed,
and the full suite re-run to confirm no reward-amount drift in the unaffected paths.
