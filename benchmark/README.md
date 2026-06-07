# REIY Bun Benchmark

Bun/TypeScript runner for the hybrid v2 flow:

`submit intents -> coordinator signs solution certificates -> solver settles batches`

## Setup

```bash
cd benchmark
bun install
```

The runner reads `../.env.testnet` by default. Override with `ENV_FILE=/path/to/env`.

Required object env:

```bash
REIY_PACKAGE_ID=0x...
AUCTION_STATE_ID=0x...
GLOBAL_CONFIG_ID=0x...
SOLVER_REGISTRY_ID=0x...
FEE_VAULT_ID=0x...
COORDINATOR_KEY_VERSION=1
```

Solver signing uses `SUI_SECRET_KEY`, `SUI_MNEMONIC`, or the active Sui CLI key. Certificate signing uses `COORDINATOR_SECRET_KEY` or `COORDINATOR_MNEMONIC`; if omitted, the solver key is reused only when it is Ed25519 and matches the onchain coordinator pubkey.

## Run

```bash
bun run doctor
bun run register-solver
COUNT=100 SETTLEMENT_CHUNK_SIZE=4 bun run e2e
```

Outputs land in `benchmark/reports/<run-id>/`:

- `plan.json`
- `certificates.json`
- `records.json`
- `summary.json`
- `settlement-batches.json`
- `figures/latency.pdf`
- `figures/gas.pdf`
- `figures/summary.pdf`
- `figures/settlement_batches.pdf`

Useful knobs:

```bash
COUNT=100
E2E_GAS_BUDGET=2000000000
SELL_AMOUNT=10000000
SELL_JITTER_BPS=250
SLIPPAGE_BPS=500
TTL_MS=3600000
DIRECTION=base_to_quote
SETTLEMENT_CHUNK_SIZE=4
SETTLEMENT_MAX_CHUNK_SIZE=4
GROSS_PAYOUT_BPS=10100
SOLUTION_TTL_MS=300000
AUTO_TOP_UP=1
AUTO_REGISTER=1
```

Manual split mode:

```bash
COUNT=100 bun run intents
SETTLEMENT_CHUNK_SIZE=4 bun run settlements
```

The settlement benchmark reports user submit gas, coordinator signing latency, settlement gas, estimated protocol fee, and estimated solver fee share. The Python chart script renders PDF figures with per-op detail and per-batch settlement breakdowns.
