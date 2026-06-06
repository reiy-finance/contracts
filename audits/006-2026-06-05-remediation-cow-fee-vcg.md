# Review 006 — Remediation of 005 (CoW fee / VCG reward)

| Field | Value |
| --- | --- |
| **Review #** | 006 |
| **Date** | 2026-06-05 |
| **Type** | Internal remediation + re-test |
| **Methodology** | Targeted fixes for [005](005-2026-06-05-internal-cow-fee-vcg-reward.md) findings + full `sui move test` |
| **Base** | working tree on top of `2a17064` (continues the 005 snapshot) |
| **Reviewer** | Internal |
| **Tests** | `sui move test` — 87 passed / 0 failed (was 86; +1 `test_custom_fee_tier_over_max_aborts`) |

> Immutable snapshot. Current status is tracked in [README.md](README.md).

## Scope

Remediation of the findings raised in review 005. Five of six are fixed in this round; the remaining
Medium (F-005-1, reward-suppression via paper allocation) is a mechanism-design decision and is left
Open with analysis below.

## Fixes

### [Fixed] F-005-2 — `close_batch` reward loop O(solvers × allocations × bids × intents)

**Was:** `distribute_solver_rewards` called `reference_score_excluding` per winning solver, and each
call re-ran `allocation_is_valid` (O(bids × intents)) across all allocations — validity recomputed
`S` times redundantly.

**Fix:** Added `auction::reference_scores_for(state, &solvers): vector<u64>`
(`sources/auction.move`). It computes `(valid, score)` per allocation **once**
(O(A×B×I)), then derives each solver's reference with O(A×B) membership + O(pairs) benchmark — overall
**O(A×B×I + S×A×B)** instead of O(S×A×B×I). `settlement::distribute_solver_rewards` now calls it once
and indexes the result vector. `reference_score_excluding` is kept as a thin single-solver wrapper.
Combined with the `max_allocations` cap (005), the close loop is now both bounded and amortized.

**Residual:** the worst-case is still bounded by `max_allocations` (default 64) — operators should tune
this down if a packed epoch ever approaches the compute budget. No longer a recompute blowup.

### [Fixed] F-005-3 — `FeeTier::Custom(ppm)` unvalidated

**Fix:** `config::set_pair_fee_tier` now matches on the tier and, for `Custom(ppm)`, asserts
`ppm ≤ MAX_VOLUME_FEE_PPM && ppm ≤ max_total_fee_ppm` (`EInvalidParam`) — same ceiling the global
`set_*_volume_fee_ppm` setters enforce. A Custom tier can no longer exceed the fee ceiling or push
`gross − volume_fee` into u64 underflow (pair brick). Regression: `test_custom_fee_tier_over_max_aborts`
(`Custom(10_001)` aborts) + positive case `Custom(5_000)` accepted in `test_pair_fee_tier_correlated`.

### [Fixed] F-005-4 — silent reward skip

**Fix:** `distribute_solver_rewards` now emits `SolverRewardSkippedEvent { epoch, solver, owed_amount,
vault_balance, fee_token }` when an earned reward cannot be paid because the vault is short (the only
way that happens is fee withdrawal between settlement and close — budget-safety otherwise guarantees
`Σ reward ≤ fees deposited`). The omission is now observable on-chain instead of vanishing silently.
The settlement→close window remains a period during which admin fee withdrawal should not run
(documented in code); reserving the budget pre-close is deferred (requires final scores, only known at
close).

### [Fixed] F-005-5 — `max_ucp_rounding_loss` dead config

**Fix:** Removed the field, default const, setter, and getter from `config.move`. The UCP equality
check is exact and the `actual_k ≥ committed_k` check needs no tolerance, so there was nothing to wire.
Eliminates an inactive-control footgun.

### [Fixed] F-005-6 — tautological `EBelowMinimum` guard / dead error

**Fix:** Removed the `assert!(gross >= net + total_fee, ...)` tautology in `finalize_settlement` and the
now-redundant `assert!(gross >= m_eff, ...)` in the test-only settle path (the floor — and thus `m_eff`,
since `protected_min = max(m_eff, floor)` — is enforced by `compute_fees`/`EBelowFloor` on both paths).
The dead `EBelowMinimum` constant in `settlement.move` was removed. (Note: `auction::EBelowMinimum` is a
separate, still-live constant used in `submit_bid` — untouched.)

## Still Open

### [Medium] F-005-1 — reward suppression via undeliverable "paper" alternative allocation

**Status:** Open — **mechanism-design decision, not a code patch.**

**Analysis this round.** The root cause is that Reiy has no equivalent of CoW's *fairness filtering*:
`reference_score_excluding` counts any allocation that passes the static `allocation_is_valid`
(payout ≥ floor), regardless of whether its proposer would ever deliver it. Quick re-examination of the
cost to the griefer: an alternative allocation must be backed by real **bid** reservations
(`required_bid_stake = max(min_stake, grief_factor × score)`) plus an **allocation** reservation. Those
are *released, not slashed*, when the allocation loses — so the cost is **capital lock-up for one
epoch** (~`grief_factor × score`, i.e. ≥1.5× the suppressed score), not a burn. So the griefing is
**soft-gated by capital, not free**, and the bias is conservative (it can only *under*-reward the
winner — never overpay the vault).

Because a true fix means importing CoW-style fairness filtering (a substantial mechanism change), and
the current behaviour is bounded + vault-safe + capital-gated, this is left Open for an explicit
decision rather than patched ad hoc. **Options (unchanged from 005):** (a) accept the conservative
bias + capital-lockup mitigation and document it as a known v1 property; (b) require reference
allocations to be backed by stake that stays locked through close (so a never-delivered reference has a
real, slashable cost); (c) implement fairness filtering. Recommend (a) for v1 mainnet with a tracking
item for (c) once multi-allocation competition is live.

## Re-verified after fixes

- Full suite green (87/87). The reward-correctness tests (`test_solver_vcg_reward_paid_from_fee_vault`
  = 30, `test_reference_uses_competing_allocation_not_just_benchmark` = 5_000, happy-path = 30) pass
  **unchanged**, confirming `reference_scores_for` is behaviour-equivalent to the per-solver version it
  replaced — the refactor is pure performance, no semantic drift.
- Build warnings unchanged at 3 (pre-existing `PairFeeTierUpdatedEvent` unused fields); no new dead
  code introduced by the fixes.

## Methodology

Each 005 finding was addressed at its cited location, a regression test added where behaviour changed
(F-005-3), and the full `sui move test` suite re-run to confirm no semantic regression — in particular
that the F-005-2 performance refactor preserved every reward amount asserted by the existing tests.
