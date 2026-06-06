# Review 010 — F-009-1 remediation: numeraire-only v1 gate

| Field | Value |
| --- | --- |
| **Review #** | 010 |
| **Date** | 2026-06-07 |
| **Type** | Internal remediation (closes the 009 mainnet blocker) |
| **Methodology** | Allowlist-boundary invariant + reachability proof + regression test |
| **Base** | working tree on top of `2a17064` (after 009) |
| **Reviewer** | Internal |
| **Tests** | `sui move test` — 88 passed / 0 failed; build warnings unchanged at 3 (pre-existing) |

> Immutable snapshot. Current status is tracked in [README.md](README.md).

## Scope

Closes **F-009-1** (cross-token VCG reward accounting, High) for the v1 mainnet launch by the audit's
recommended option **(c): numeraire-only**. The chosen control mirrors how CoW handles multi-token
batches — a single common unit for both scoring *and* the reward budget — but achieves it the
simplest safe way for v1: by forbidding non-numeraire-Buy pairs entirely, so every protocol fee is
already in the numeraire and no on-chain conversion is required.

## [Fixed] F-009-1 — numeraire-only allowlist invariant

**Primary gate.** `config::add_supported_pair<Sell, Buy>` now asserts
`type_name<Buy> == numeraire_type(c)` (`ENonNumeraireBuy`). A directed pair can be allowlisted only
if its Buy token is the numeraire.

**Closing the back door.** `config::set_numeraire<N>` now asserts `supported_pairs` is empty
(`ENumeraireLocked`), so the numeraire cannot be swapped out from under already-allowlisted pairs
(which would silently turn them non-numeraire-Buy and reopen the hole). Operational order is forced:
set the numeraire first, then allowlist pairs.

**Why this closes the finding (reachability proof).**
- `submit_intent_inner` asserts the pair is supported (`assert_pair_supported`). With the gate, every
  supported pair has `Buy == numeraire`, so **every intent that can exist buys the numeraire**.
- Therefore every settlement runs through `settle_intent_numeraire`, which itself asserts
  `Buy == numeraire` (`ENotNumeraire`) and deposits into `FeeVault<Buy = numeraire>`.
- `accumulate_solver_fee` consequently only ever receives **numeraire** fees, so
  `solver_fee_of(solver)` and the reward cap `β × fee_i` are denominated in the numeraire — the same
  unit as `marginal` and as the `FeeVault<N>` the reward is paid from. The denomination blow-up and
  cross-vault subsidy described in F-009-1 are both unreachable.
- The non-numeraire `settle_intent` (with its `normalize_surplus` / numeraire-pool path) is retained
  in the source for a future multi-token v2 but is **unreachable** under this invariant: no
  non-numeraire intent can be created to feed it.

**Budget-safety restored.** With all fees in the numeraire, the 005/007 inequality holds again:
`Σ reward_i ≤ β × Σ fee_i ≤ fees in FeeVault<N>`, and the per-tx balance guard remains as a
backstop.

**Regression.** `config_tests::test_non_numeraire_buy_pair_rejected` — with numeraire = USDC,
`add_supported_pair<TOKA, TOKB>` (Buy = TOKB) aborts `ENonNumeraireBuy`. The test fixture
`test_helpers::setup_all` dropped its former `add_supported_pair<TOKA, TOKB>` line (it was never
exercised by any settle test) and now allowlists only numeraire-Buy pairs (`TOKA/USDC`, `TOKB/USDC`).

## Deferred to v2 (documented, not a blocker)

- **Multi-token Buy + reward routing.** To support buying non-numeraire tokens while keeping rewards
  correct, v2 must denominate the fee cap in the numeraire (normalize each fee with the same
  `num_pool` mid already read in `settle_intent`) **and** fund the numeraire reward budget — either by
  routing/ converting non-numeraire fees into `FeeVault<numeraire>` on-chain (a DeepBook swap at
  settlement, the closest analogue to CoW selling fees to ETH) or by explicitly treating the
  numeraire vault as a governance-funded reward pool. This must ship with the non-numeraire settle +
  reward regression tests called out in 009, and should pair with F-009-4 (TWAP mid) since the reward
  would then depend on a manipulable price.
- The non-numeraire `settle_intent`, `normalize_surplus`, and the `numeraire_pools` config
  (`add_numeraire_pool` / `numeraire_pool_id`) are retained as that v2 groundwork; they are inert
  under v1.

## Mainnet gate status after this review

- F-009-1 (High) — **Fixed** (this review). No longer a blocker.
- F-009-2 / F-009-3 (Informational dead code/config) — still open, hygiene only.
- F-009-4 (DeepBook-mid in reward) — not reachable under numeraire-only v1 (no `num_pool`
  normalization path executes), so **not a v1 blocker**; revisit with multi-token v2.
- Production `GlobalConfig` must set the numeraire first and allowlist only `*/numeraire` pairs — now
  enforced on-chain, not just by operator discipline.

## Methodology

Placed the invariant at the single allowlist boundary, proved by construction that it makes every
intent numeraire-Buy and the dangerous fee path unreachable, locked the numeraire against post-hoc
change, and added a negative regression test. Full suite re-run (88/88).
