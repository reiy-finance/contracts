# Reiy V2 Migration

## Architecture

Reiy v2 uses onchain intent escrow, offchain coordination, and onchain settlement verification.

User `Intent` objects stay onchain and hold escrowed sell assets. Bid collection, scoring, winner selection, pair benchmarks, and retry orchestration move to an offchain **Execution Coordinator** service. The name is intentionally not CoW “Autopilot,” although the role is CoW-inspired.

Settlement is authorized by a coordinator-signed `SolutionCertificate`. The Move contract verifies the Ed25519 signature, checks the solver caller, validates epoch/deadline/token types/intent IDs/fills/gross payouts/protected minimums, then releases each intent into settlement.

## What Moves Offchain

- Bid submission
- Allocation and winner selection
- Pair benchmark and reference scoring
- Winner commit
- Solver retry and orchestration

## What Stays Onchain

- Intent escrow
- Intent cancellation until consumption
- Coordinator signature and certificate verification
- Payout floor enforcement
- Fee split
- Settlement events

## Why

The previous benchmark showed `submit_intent` averaging about `0.01026 SUI`, mostly storage driven. Keeping onchain bid, allocation, benchmark, winner, and VCG close state added more storage churn and made the protocol fee tradeoff painful.

V2 keeps user protection onchain while removing the onchain auction state machine. `AuctionState` is now a slim protocol state object, and the `Intent` object is the source of truth for escrow.

## Trust Model

Users are protected by onchain minimum output, SBBO floor, deadline, token type, epoch, and certificate checks.

Best execution is coordinator and solver-market dependent in v1. The coordinator is trusted operationally to collect quotes, score solutions, choose winners, sign certificates, and reissue certificates if a solver misses expiry. Future versions may add optimistic challenges or multi-coordinator signatures.

## Fee Config

Launch defaults are user-fair and solver-aligned:

- Standard volume fee: `75 ppm` / `0.75 bps`
- Correlated fee: `10 ppm` / `0.1 bps`
- Surplus fee: `100_000 ppm` / `10%`
- Surplus cap: `1_000 ppm` / `10 bps`
- Max total fee: `1_500 ppm` / `15 bps`
- Solver fee share: `350_000 ppm` / `35%`

The old close-time VCG reward is removed. Settlement now splits the total fee immediately:

`total_fee = volume_fee + surplus_fee`

`solver_reward = total_fee * solver_fee_share_ppm`

`protocol_fee = total_fee - solver_reward`

## Migration Notes

This is a breaking architecture change. Use a fresh package and fresh testnet objects instead of an in-place shared-object layout upgrade.

Old testnet package/state objects are deprecated. Active old intents should be settled, cancelled, or reset before cutover.

Fresh deployment should initialize:

- `GlobalConfig`
- slim `AuctionState`
- `SolverRegistry`
- canonical `FeeVault<numeraire>`
- coordinator public key and key version
- supported numeraire-buy pairs

## Benchmarking

The v2 benchmark under `benchmark/` measures:

- `submit_intent`
- `coordinator_sign_solution`
- `settle_solution` at average batch size 3-4
- total user cost: submit gas + settlement gas + protocol fee

Run:

```bash
cd benchmark
bun install
COUNT=100 SETTLEMENT_CHUNK_SIZE=4 bun run e2e
```

Charts are generated as PDFs in `benchmark/reports/<run-id>/figures/`.

Target: reduce `submit_intent` below the prior `0.01026 SUI`, ideally below `0.006 SUI`, while reporting settlement gas and total cost against Cetus/router baselines.
