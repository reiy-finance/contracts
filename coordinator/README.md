# Reiy Execution Coordinator

Bun/TypeScript MVP for offchain coordination.

It indexes Reiy events, keeps an offchain orderbook, accepts solver quotes, signs `SolutionCertificate` payloads, and stores emitted certificates in a JSON store. Onchain contracts still enforce escrow ownership, deadlines, protected minimums, solver identity, and fee split.

## Run

```bash
bun install
REIY_PACKAGE_ID=0x... \
AUCTION_STATE_ID=0x... \
GLOBAL_CONFIG_ID=0x... \
SUI_NETWORK=testnet \
COORDINATOR_KEY_VERSION=1 \
COORDINATOR_SECRET_KEY=suiprivkey... \
bun run start
```

Set `SUI_RPC_URL` to override the default fullnode, or `COORDINATOR_INDEXER=0` to disable event polling.

## API

- `GET /health`
- `GET /indexer/status`
- `POST /indexer/sync`
- `GET /orderbook?epoch=0&sellType=...&buyType=...`
- `POST /intents`
- `POST /quotes`
- `POST /solutions/sign`
- `GET /certificates`

The indexer polls the package `events` module and applies `IntentCreated`, `IntentUpdated`, `IntentCancelled`, and settlement events. The MVP store is JSON-backed; Postgres can replace `JsonStore` without changing the certificate format.
