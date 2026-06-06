# Audit Log

Security reviews of the REIY Move package.

## Convention

- One file per review: `NNN-YYYY-MM-DD-<type>-<scope>.md` — `NNN` is a sequential review number
  (zero-padded), unique and never reused. Multiple reviews can share a date.
- **Review files are immutable snapshots.** A review records its findings and their status *as of
  that review*. Never edit an old review file to change a finding's outcome.
- **New round of findings = new review file.** When a later review fixes, re-tests, or supersedes an
  earlier finding, write a new file referencing the old one — do not rewrite history.
- **This README is the living trace.** The Reviews table and the consolidated findings register
  below always reflect the *current* status across all reviews.

**Severity:** Critical / High / Medium / Low / Informational
**Status:** Open → Acknowledged → Fixed (review NNN) / Resolved (false positive) / Won't Fix

## Reviews

| # | Date | Type | Scope | Report |
| --- | --- | --- | --- | --- |
| 001 | 2026-05-30 | Internal (STRIDE) | `intent_book`, `settlement` | [001-2026-05-30-internal-stride.md](001-2026-05-30-internal-stride.md) |
| 002 | 2026-05-30 | Internal (verification) | open findings of 001 | [002-2026-05-30-finding-verification.md](002-2026-05-30-finding-verification.md) |
| 003 | 2026-05-30 | Internal (remediation) | confirmed findings of 001/002 | [003-2026-05-30-fixes.md](003-2026-05-30-fixes.md) |
| 004 | 2026-06-01 | Internal (STRIDE) | `solver_registry`, `treasury`, slash mechanism, `settlement` re-audit | [004-2026-06-01-internal-treasury-slash.md](004-2026-06-01-internal-treasury-slash.md) |
| 005 | 2026-06-05 | Internal (STRIDE) | CoW fee model (`fee_vault`, `compute_fees`, fee tiers), VCG per-solver reward, `close_batch` rewrite, `max_allocations` cap | [005-2026-06-05-internal-cow-fee-vcg-reward.md](005-2026-06-05-internal-cow-fee-vcg-reward.md) |
| 006 | 2026-06-05 | Internal (remediation) | fixes for 005 findings (F-005-2/3/4/5/6) + re-test | [006-2026-06-05-remediation-cow-fee-vcg.md](006-2026-06-05-remediation-cow-fee-vcg.md) |
| 007 | 2026-06-06 | Internal (remediation) | F-005-1 closed via benchmark-only reference; corrections to 005/006 | [007-2026-06-06-reference-hardening.md](007-2026-06-06-reference-hardening.md) |
| 008 | 2026-06-07 | Internal (optimization) | drop dead Bid/Selection collections after winner selection to shrink settlement-phase `AuctionState`; correctness preserved | [008-2026-06-07-settlement-object-size.md](008-2026-06-07-settlement-object-size.md) |
| 009 | 2026-06-07 | Internal (STRIDE) | full-package mainnet-readiness re-audit; cross-token reward hole (F-009-1) + dead-code hygiene; re-confirmed 004 fixes | [009-2026-06-07-mainnet-readiness.md](009-2026-06-07-mainnet-readiness.md) |
| 010 | 2026-06-07 | Internal (remediation) | F-009-1 closed for v1 via numeraire-only allowlist gate (+ numeraire lock); regression test | [010-2026-06-07-numeraire-only-v1.md](010-2026-06-07-numeraire-only-v1.md) |

## Findings register (current status)

| Severity | Title | Found in | Status |
| --- | --- | --- | --- |
| High | Cross-token VCG reward: per-solver fee cap mixes Buy-token units / drawn from numeraire vault | 009 | Fixed (010) — v1 numeraire-only allowlist gate; multi-token Buy deferred to v2 |
| Medium | Expired winning intent re-queued / unfair slash | 001 | Fixed (003) |
| Medium | Fully-drained partial-fill intent leaves a zombie shared object | 001 | Fixed (003) |
| Medium | Unbounded loops in `close_batch` / `distribute_rewards` / `trigger_fallback` enable gas DoS | 001 | Mitigated (005 `max_allocations` cap; 007 removed allocation scan from reward path) |
| Medium | Reward suppression via undeliverable "paper" alternative allocation inflates `referenceScore_i` | 005 | Fixed (007) — benchmark-only reference (trust-minimized) |
| Medium | `close_batch` reward loop O(solvers × allocations × bids × intents); validity recomputed per solver | 005 | Fixed (006; superseded 007 — reward loop now O(solvers × pairs), no allocation scan) |
| Medium | Suspend-threshold evasion via deregister + re-register | 004 | Fixed (009 — confirmed) — `slash_history` persists slash count across deregister; Sybil-via-new-address residual accepted |
| Medium | Protocol treasury funds permanently locked (no withdrawal path) | 004 | Fixed/moot (009 — confirmed) — `fee_vault::withdraw_fees` + `treasury::withdraw_slashed_stake` (AdminCap); fees no longer route to treasury |
| Low | `FeeTier::Custom(ppm)` unvalidated — admin can exceed max fee or brick a pair | 005 | Fixed (006) |
| Low | AdminCap fee withdrawal between settlement and close silently starves pending rewards | 005 | Fixed (006) — `SolverRewardSkipped` event (budget reservation deferred) |
| Low | Object-binding: treasury/registry not pinned to canonical IDs | 004 | Fixed (009 — confirmed) — registry/treasury/fee-vault all pinned & asserted on hot paths; canonical IDs set-once |
| Low | Overpaid protocol fee in `close_batch` not refunded | 001 | Fixed (003); moot since 005 (no close fee coin) |
| Low | `update_intent_params` gating | 001 | Reclassified (002): dead code, latent |
| Informational | Fallback bounty payable to the at-fault solver | 004 | Fixed (009 — confirmed) — `trigger_fallback` zeroes bounty when caller ∈ slashed owners |
| Informational | Dead treasury numeraire-revenue path (`deposit_fee`/`withdraw_protocol_fees`/`withdraw_reward` uncalled) | 009 | Open (hygiene) |
| Informational | `price_oracle_max_age_ms` is dead config (never read by `read_mid_price`) | 009 | Open (hygiene) |
| Informational | VCG reward now depends on live DeepBook mid (manipulation surface); bounded by `β × fee` cap once F-009-1 fixed | 009 | Open — TWAP recommended for multi-token Buy |
| Informational | `auctioneer_share_bps` / `auctioneer_reward_cap` are dead config | 004 | Resolved (005) — removed in config rewrite |
| Informational | `max_ucp_rounding_loss` is dead config | 005 | Fixed (006) — removed |
| Informational | Tautological `EBelowMinimum` guard; unreachable on production path | 005 | Fixed (006) — removed |
| Informational | `total_stake_slashed` accounting split across two functions (fragile) | 004 | Open |
| Informational | `reactivate_solver` does not reset `slash_count` | 004 | Acknowledged — by design (strict probation) |
| Informational | Score normalization trusts live DeepBook mid | 001 | Acknowledged |
| Informational | `settle_*` doesn't re-check `sender == receipt.solver` | 001 | Acknowledged |
| Informational | `take_intent_partial` multi-take double-count | 001 | Resolved — false positive (002) |
