# Review 009 — Mainnet-readiness review (full package)

| Field | Value |
| --- | --- |
| **Review #** | 009 |
| **Date** | 2026-06-07 |
| **Type** | Internal (STRIDE) full-package re-audit for mainnet deployment |
| **Methodology** | Whole-tree read of all 11 modules + integrated mechanism walk + open-finding re-test |
| **Base** | working tree on top of `2a17064` (after reviews 005–008) |
| **Reviewer** | Internal |
| **Tests** | `sui move test` — 87 passed / 0 failed; build warnings: 3 pre-existing (`PairFeeTierUpdatedEvent`) |

> Immutable snapshot. Current status is tracked in [README.md](README.md).

## Scope & verdict

Full re-audit of the integrated package ahead of mainnet, with emphasis on the CoW fee / VCG reward
mechanism (005–007) and the 008 object-size change. Trilemma priority as stated by the project:
**security ≫ decentralization > performance.**

**Verdict: NOT mainnet-ready as-is.** One **High** finding (F-009-1, cross-token reward accounting)
is a blocker for any deployment that allowlists a directed pair whose Buy token is not the numeraire
— which the current test config already does (`TOKA/TOKB`). The remaining new findings are
Informational cruft. Several previously-open 004/005 findings are confirmed **fixed in code** and
their register entries are updated.

---

## [High] F-009-1 — Cross-token VCG reward accounting breaks the per-solver fee cap

**Where.** `settlement::finalize_settlement` → `auction::accumulate_solver_fee` (raw `total_fee`),
consumed by `settlement::distribute_solver_rewards` as `reward_cap = β × solver_fee_of(solver)`,
paid from the single numeraire `FeeVault<N>` in `close_batch<N>`.

**Mechanism.** Protocol fees are split per settlement in the **Buy token** and deposited into
`FeeVault<Buy>` — a *per-token* vault. `accumulate_solver_fee` adds that `total_fee` into one scalar
`solver_fee_collected[solver]` **without normalizing to numeraire**. At close, `close_batch` receives
only the numeraire vault `FeeVault<N>` and pays each solver `min(marginal, β × solver_fee_of)` from
it, where `marginal` is in **normalized numeraire units** but `solver_fee_of` is a **sum of raw,
possibly non-numeraire, possibly different-decimal** fee amounts.

**Why it is reachable.** The protocol supports non-numeraire Buy tokens by design: `settle_intent`
(as opposed to `settle_intent_numeraire`) exists precisely to normalize a non-numeraire Buy via a
`Buy/Numeraire` DeepBook pool, and the test config already allowlists `add_supported_pair<TOKA,
TOKB>` with numeraire = `USDC` (so `TOKB ≠ N`). An intent buying `TOKB` settles its fee into
`FeeVault<TOKB>`, never into `FeeVault<USDC>`.

**Impact.**
1. **Denomination blow-up → numeraire-vault drain.** `reward_cap` is computed as `β ×
   (fee number in the Buy token's own base units)`. If the Buy token has more decimals or a smaller
   unit value than the numeraire, that raw number is enormous relative to numeraire units, so the
   cap is effectively unbounded. A solver that produced any genuine numeraire-normalized `marginal`
   can then be paid out of `FeeVault<N>` up to the **entire current vault balance** — funded by
   protocol fees and other solvers' fees that accumulated in the numeraire vault across batches,
   not by anything this solver paid into it. The per-tx guard
   `fee_vault::balance(fee_vault) >= solver_reward` prevents an underflow/abort but does **not**
   prevent the misallocation; it just caps theft at the available balance.
2. **Silent non-payment.** A batch whose intents all buy a non-numeraire token deposits zero into
   `FeeVault<N>`, so legitimate rewards there are skipped (`SolverRewardSkipped`) despite fees having
   been collected (in the other vault).
3. **Invariant broken.** The budget-safety claim from 005/007 — `Σ reward_i ≤ β × Σ fee_i ≤ fees in
   the vault` — holds only when every settled Buy token equals the numeraire. Across tokens it is
   false, because the `fee_i` that justifies a reward is not in the vault the reward is drawn from.

**Recommended fix (security-first).** Pick one, before allowlisting any non-numeraire-Buy pair:
- **(a) Numeraire-only reward accrual (smallest, safest for v1).** In `finalize_settlement`,
  accumulate into `solver_fee_collected` **only** when `Buy == numeraire` (or accumulate the
  numeraire-*normalized* fee using the same `mid` already read in `settle_intent`). This makes
  `reward_cap` a true numeraire quantity and removes the decimals blow-up. Cross-vault subsidy is
  still possible in principle if non-numeraire fees are normalized and paid from `FeeVault<N>`, so
  pair it with (b).
- **(b) Single reward currency = numeraire, single source = `FeeVault<N>`.** Require that the reward
  budget is the numeraire vault only, and that `reward_cap` is the numeraire-normalized fee. Document
  that the reward pool is cross-batch numeraire fees and that non-numeraire fees fund only the
  protocol (withdrawn via `fee_vault::withdraw_fees<Buy>`), not solver rewards.
- **(c) Strictest for v1:** restrict the mainnet allowlist to pairs whose Buy token is the numeraire
  and ship `settle_intent_numeraire` only, deferring multi-token Buy + its reward routing to a later
  release. This sidesteps the issue entirely with no mechanism risk.

A regression test settling a non-numeraire-Buy intent and asserting the reward cap is in numeraire
units (and that `FeeVault<N>` is not drained by a `TOKB` fee) must be added with the fix; the current
suite exercises only `settle_intent_numeraire`, so this path is **untested**.

---

## [Informational] F-009-2 — Dead treasury numeraire-revenue path

`treasury::deposit_fee`, `treasury::withdraw_protocol_fees`, and `treasury::withdraw_reward` have **no
callers** (verified by grep over `sources/` and `tests/`). Protocol fees are routed to `FeeVault<T>`
(via `fee_vault::deposit_fee`) and withdrawn via `fee_vault::withdraw_fees`; solver rewards are paid
via `fee_vault::pay_reward`. Consequently `ProtocolTreasury.balance<N>` is always zero on the
production path and the only live treasury role is holding **slashed Stake**
(`deposit_slashed_stake` / `withdraw_slashed_stake`) and the fallback-bounty counter. Recommend
removing the dead numeraire-revenue functions (and `total_collected`) to avoid operator confusion
about where fees are withdrawn, or wiring them if a treasury fee path is actually intended. Mirrors
the dead-config class already cleaned in 006 (F-005-5).

## [Informational] F-009-3 — `price_oracle_max_age_ms` is dead config

`config.price_oracle_max_age_ms` (default 60_000) has a setter and getter but is **never read**:
`price_adapter::read_mid_price` only enforces `mid >= min_sbbo_mid_price`. DeepBook's `mid_price` is
derived live from the order book rather than a timestamped oracle, so a max-age check may not even be
meaningful; either wire an explicit staleness/clock check if one is intended, or remove the
parameter. Same dead-config hygiene concern as F-005-5.

## [Informational] F-009-4 — VCG reward elevates the existing DeepBook-mid trust assumption

Score normalization for non-numeraire settlements trusts the live `num_pool` mid (acknowledged since
001). With `β = 50%` (rewards now ON, 005+), that mid no longer affects only fee accounting — it now
feeds `marginal` and therefore solver **reward**. A solver active on the same DeepBook pool could
nudge the mid to inflate its normalized score. The `β × fee` cap bounds the payout **once F-009-1 is
fixed** (today the cap is unreliable, compounding F-009-1). Recommend, when multi-token Buy ships, a
TWAP / multi-sample mid for the numeraire pool used in `normalize_surplus`. Not a blocker for a
numeraire-only v1 (option (c) above).

---

## Confirmed FIXED since their original review (register updated)

These were carried as **Open** in the README register; code inspection in this review confirms they
are now closed. (Fixes predate this review and lacked a trace entry — recorded here.)

- **F-004-1 (Suspend-threshold evasion via deregister + re-register) — Fixed.**
  `SolverRegistry.slash_history: Table<address, u64>` persists a solver's slash count independently of
  the `solvers`/`stakes` entries that `deregister_solver` removes. `register_solver` reads
  `slash_history` and restores `slash_count`, immediately re-`Suspended` if `>= SUSPEND_THRESHOLD`
  (3). Re-registration cannot reset reputation. *Residual (inherent, accepted):* a brand-new address
  starts clean (Sybil); this is intrinsic to a permissionless solver set and is gated economically by
  `min_solver_stake`.
- **F-004-2 (Protocol funds permanently locked) — Fixed / moot.** Withdrawal paths exist:
  `fee_vault::withdraw_fees<T>` (AdminCap) for protocol fees and
  `treasury::withdraw_slashed_stake<N, Stake>` (AdminCap) for slashed stake. The original concern
  (treasury with no withdrawal) is moot because fees no longer route through the treasury (see
  F-009-2).
- **F-004-3 (Object-binding not pinned to canonical IDs) — Fixed.** All three shared collaborators are
  pinned in `GlobalConfig` and asserted on the hot paths: `assert_solver_registry_id`
  (bid/benchmark/allocation/settle/close/fallback), `assert_protocol_treasury_id` (fallback), and
  `assert_fee_vault_id` (`fee_vault::assert_canonical`, settle/close). Canonical IDs are set-once
  (`ECanonicalObjectAlreadySet`).
- **F-004-5 (Fallback bounty payable to the at-fault solver) — Fixed.** `trigger_fallback` collects
  `slashed_owners` and sets `bounty = 0` when `ctx.sender()` is among them, so a faulted solver
  cannot self-pay the fallback bounty. (Default `fallback_bounty_bps = 0` keeps it inert regardless.)

## Re-verified clean

- **008 object-size change.** `committed_benchmark_refs` captures `{auctioneer, total_score}` for every
  benchmark pair at selection; committed pairs ⊆ benchmark pairs in both winner branches
  (allocation-winner via `validate_allocation`'s benchmark requirement, fallback-winner by
  construction), so `reference_score_excluding` reads identical values to the pre-008
  `pair_benchmarks` source. Cleared `bids`/`allocations`/`pair_benchmarks` are provably unread after
  selection. No invariant regressed; reward amounts unchanged (tests green).
- **Settlement hot-potato.** `SettlementReceipt` has no abilities → must be consumed by `settle_*` in
  the same PTB as `take_*`; double-settle blocked by `mark_intent_settled` + `is_intent_settled`.
- **Partial-fill zombie.** `consume_intent_partial` requires `fill < remaining` (full path deletes the
  object), so no zero-balance zombie (001 fix intact).
- **Fee math.** `compute_fees` floors all fees, caps surplus fee and total fee, and asserts
  `payout_after_volume >= protected_min` (`EBelowFloor`) — user floor preserved before any fee split.

---

## Mainnet gate (must-do before deploy)

1. **Resolve F-009-1** by one of (a)/(b)/(c). For the fastest safe launch, **(c) numeraire-only Buy**
   for v1 is recommended; it removes the entire cross-token surface with zero mechanism change.
2. If shipping multi-token Buy now, add the non-numeraire settle + reward regression tests called out
   in F-009-1 and address F-009-4 (mid manipulation) with a TWAP source.
3. Clean F-009-2 / F-009-3 dead code/config (hygiene; not a blocker).
4. Confirm production `GlobalConfig` allowlist matches the chosen F-009-1 resolution (do **not**
   allowlist `TOKA/TOKB`-style non-numeraire pairs under option (c)).

## Methodology

Read every module top-to-bottom; traced the value flow user-intent → bid → benchmark → allocation →
selection → settle (fee split, normalization) → close (reward) → fallback (slash); grepped every
cross-module call site for the fee/reward/stake/canonical-ID paths; re-derived the budget-safety
inequality under multi-token settlement (where it breaks); and re-confirmed each previously-open
004/005 finding against current code.
