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

## Findings register (current status)

| Severity | Title | Found in | Status |
| --- | --- | --- | --- |
| Medium | Expired winning intent re-queued / unfair slash | 001 | Fixed (003) |
| Medium | Fully-drained partial-fill intent leaves a zombie shared object | 001 | Fixed (003) |
| Medium | Unbounded loops in `close_batch` / `trigger_fallback` enable gas DoS | 001 | Open (not verified) |
| Low | Overpaid protocol fee in `close_batch` not refunded | 001 | Fixed (003) |
| Low | `update_intent_params` gating | 001 | Reclassified (002): dead code, latent |
| Informational | Score normalization trusts live DeepBook mid | 001 | Acknowledged |
| Informational | `settle_*` doesn't re-check `sender == receipt.solver` | 001 | Acknowledged |
| Informational | `take_intent_partial` multi-take double-count | 001 | Resolved — false positive (002) |
