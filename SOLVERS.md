# Reiy — Solver Integration Guide

Concise reference for building a solver against the Reiy Move package. Hybrid model: intents escrow
on-chain, the off-chain **Execution Coordinator** scores bids and signs the winning solution, and the
**solver** atomically settles it on-chain.

## 1. Roles

| Role | Where | Responsibility |
| --- | --- | --- |
| User | on-chain | Submits an `Intent<Sell, Buy>` escrowing the sell asset + a protected minimum. |
| Execution Coordinator | off-chain | Collects bids, selects + Ed25519-signs one `SolutionMessage` per solver. |
| **Solver (you)** | off-chain + on-chain | Bid to the Coordinator; on win, source liquidity and settle the signed solution in one PTB. |

## 2. Prerequisites

- **Register** in `SolverRegistry` with a stake `≥ min_solver_stake`; stay *active* (`is_active`).
  ```move
  solver_registry::register_solver<Stake>(registry, config, stake: Coin<Stake>, url, ctx)
  ```
- **Supported pairs.** A pair is settleable when `add_supported_pair<Sell, Buy>` is enabled and
  `FeeVault<Buy>` is registered in config.

## 3. Solution certificate

The Coordinator signs the BCS bytes of `SolutionMessage` with its Ed25519 key
(`config.execution_coordinator_pubkey`, `key_version`). You relay these fields verbatim into
`verify_solution`. Signed binding fields:

| Field | Meaning |
| --- | --- |
| `protocol_state_id`, `config_id`, `key_version` | Pin the exact `AuctionState`, `GlobalConfig`, coordinator key. |
| `epoch` | Must equal the live `AuctionState` epoch. |
| `solution_id` | Opaque coordinator id (for events/tracing). |
| `solver` | Must equal the tx sender. |
| `sell_type`, `buy_type` | Must match the `<Sell, Buy>` of the call. |
| `intent_ids[]`, `fills[]`, `gross_payouts[]`, `protected_mins[]` | Per-intent settlement plan (parallel vectors, settled in order). |
| `expires_at_ms` | Certificate deadline (`clock ≤ expires_at_ms`). |

## 4. Settlement flow (single PTB)

```move
// 1. Verify the coordinator signature → hot-potato authorization.
let mut auth = settlement::verify_solution<Sell, Buy>(
    state, config, solution_id, solver,
    intent_ids, fills, gross_payouts, protected_mins,
    expires_at_ms, signature, clock, ctx,
); // SolutionAuth<Sell, Buy>

// 2. For each intent, in certificate order, take the escrowed sell coin.
let (sell_coin, receipt) = settlement::take_authorized_intent_full<Sell, Buy>(
    state, &mut auth, intent, clock, ctx,
);
// partial fill (intent stays, residual rolls to next epoch):
// settlement::take_authorized_intent_partial<Sell, Buy>(state, &mut auth, &mut intent, clock, ctx)

// 3. Source liquidity with `sell_coin` (e.g. DeepBook), produce `payout: Coin<Buy>`.

// 4. Deliver payout; contract splits fees, pays user net, pays your fee share.
settlement::settle_intent<Sell, Buy, Stake>(
    state, registry, config, fee_vault, receipt, payout, ctx,
);
```

`take_*` advance `auth` sequentially: intent `i` must equal `intent_ids[i]`. Settle each receipt in
the same PTB.

## 5. Invariants you must satisfy

- `payout.value() == gross_payout` for that intent (exact).
- `gross_payout ≥ protected_min ≥ intent.min_amount_out` (and `≥ m_eff` per fill).
- `gross_payout − volume_fee ≥ protected_min` (floor holds after the volume fee).
- Full fill consumes the whole remaining intent; partial fill is `0 < fill < remaining`.
- Intent not expired, not already (partial-)filled this epoch, `target_epoch == epoch`.

Violations abort the whole PTB — escrow never moves on a bad settlement.

## 6. Fees & your reward

Per settled intent, on `gross` payout in the `Buy` token:

| Component | Rule | Default |
| --- | --- | --- |
| Volume fee | `gross × volume_fee_ppm(pair)` | 75 ppm std / 10 ppm correlated |
| Surplus fee | `min(surplus_share × (gross−protected_min), cap × gross)` | 10% share, 0.10% cap |
| Total fee | `min(volume+surplus, max_total_fee_ppm × gross)` | ≤ 0.15% |
| **Your share** | `total_fee × solver_fee_share_ppm`, paid to you immediately | **35%** |
| Protocol | remainder → `FeeVault<Buy>` | 65% |

User receives `net = gross − total_fee`.

## 7. Events to index

| Event | When |
| --- | --- |
| `IntentCreatedEvent` | New intent available to bid on. |
| `SolutionAuthorizedEvent` | A solution passed `verify_solution`. |
| `SettlementEvent`, `SettlementFeeChargedEvent` | Per-intent settlement + fee breakdown. |
| `SolverFeePaidEvent` | Your fee share paid. |
| `EpochAdvancedEvent` | Epoch rolled (`advance_epoch`). |

## 8. Key aborts

`ENotAuthorizedSolver` (sender ≠ cert solver) · `EBadSolutionSignature` · `EExpiredSolution` ·
`EWrongEpoch` · `EIntentMismatch` (out-of-order take) · `EBadGrossPayout` (payout ≠ cert) ·
`EBelowProtectedMinimum` / `EBelowFloor` (user protection) · `ESolverNotActive` (stake too low) ·
`EWrongCanonicalObject` (wrong fee vault).
