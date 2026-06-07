# REIY Bun Benchmark

Bun/TypeScript runner for testnet submit-intent and submit-bid load tests.

## Setup

```bash
cd benchmark
bun install
```

The runner reads `../.env.testnet` by default. Override with `ENV_FILE=/path/to/env`.

Signing uses, in order:

```bash
export SUI_SECRET_KEY=suiprivkey1...
# or
export SUI_MNEMONIC="..."
# or the active key in ~/.sui/sui_config/sui.keystore
```

## Run

```bash
bun run doctor
bun run register-solver
COUNT=100 SELL_AMOUNT=10000000 bun run e2e
```

Outputs land in `benchmark/reports/<run-id>/`:

- `plan.json`
- `records.json`
- `summary.json`
- `bid-batches.json` when bid batches are submitted
- `figures/latency.pdf`
- `figures/gas.pdf`
- `figures/summary.pdf`
- `figures/bid_batches.pdf` when bid batches are submitted

Useful knobs:

```bash
COUNT=50
E2E_GAS_BUDGET=2000000000
SELL_AMOUNT=10000000
SELL_JITTER_BPS=250
SLIPPAGE_BPS=500
TTL_MS=3600000
DIRECTION=base_to_quote
BID_CHUNK_SIZE=10
BID_MAX_CHUNK_SIZE=10
BID_PAYOUT_MULTIPLIER=1
STAKE_RESERVE_UNIT=1000000000
AUTO_TOP_UP=1
FULL_SELECTION=1
AUTO_REGISTER=1
```

`BID_CHUNK_SIZE` controls intents per `submit_bid` tx. The default cap is `BID_MAX_CHUNK_SIZE=10`, so `COUNT=100` produces about 10 bid transactions for useful batch statistics. Raise both values only when intentionally stress-testing a larger single bid call.

Each bid tx reserves solver stake. With the defaults, `COUNT=100` and `BID_CHUNK_SIZE=10` needs roughly 12 SUI stake for 10 bids plus benchmark/allocation reservations. `AUTO_TOP_UP=1` reads current registry stake and tops up only the deficit before bidding.

`BID_PAYOUT_MULTIPLIER=1` bids at exact minimum output and keeps EPSR simple. Use `2` for 2x payouts if the solver has enough stake.

`bun run e2e` stages: optional solver register, submit intents, advance to Bid, submit bids, advance to AllocationSelection, submit pair benchmark, submit allocation, advance to Settlement. If solver is already registered, `AUTO_REGISTER=1` may log a skipped register tx and continue.

Manual split mode is still available:

```bash
COUNT=100 bun run intents
bun run advance
BID_CHUNK_SIZE=10 bun run bids
```

If a previous benchmark is stuck in Settlement past its deadline, reset with fallback first:

```bash
bun run reset
```
