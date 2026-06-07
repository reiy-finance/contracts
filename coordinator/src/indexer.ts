import { SuiJsonRpcClient, type EventId, type SuiEvent } from '@mysten/sui/jsonRpc';
import type { CoordinatorConfig, IntentSnapshot } from './types.ts';
import { JsonStore } from './store.ts';

const decoder = new TextDecoder();

export class EventIndexer {
  #client: SuiJsonRpcClient;
  #config: CoordinatorConfig;
  #store: JsonStore;
  #running = false;
  #timer?: ReturnType<typeof setInterval>;

  constructor(config: CoordinatorConfig, store: JsonStore) {
    this.#config = config;
    this.#store = store;
    this.#client = new SuiJsonRpcClient({ url: config.rpcUrl, network: config.network });
  }

  start() {
    if (!this.#config.indexerEnabled) return;
    void this.sync();
    this.#timer = setInterval(() => void this.sync(), this.#config.indexerPollMs);
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
  }

  status() {
    return this.#store.indexer();
  }

  async sync() {
    if (this.#running) return this.status();
    this.#running = true;
    let cursor = this.status().cursor as EventId | undefined;
    let indexed = 0;

    try {
      while (true) {
        const page = await this.#client.queryEvents({
          query: {
            MoveEventModule: {
              package: this.#config.packageId,
              module: 'events',
            },
          },
          cursor: cursor ?? null,
          limit: this.#config.indexerPageSize,
          order: 'ascending',
        });

        for (const event of page.data) {
          await this.#apply(event);
          cursor = event.id;
          indexed += 1;
          await this.#store.setIndexerCursor(event.id, 1);
        }

        if (!page.hasNextPage || !page.nextCursor || page.data.length === 0) break;
        cursor = page.nextCursor;
      }

      if (indexed === 0 && cursor) await this.#store.setIndexerCursor(cursor, 0);
      return this.status();
    } catch (error) {
      await this.#store.setIndexerError(error instanceof Error ? error.message : String(error));
      throw error;
    } finally {
      this.#running = false;
    }
  }

  async #apply(event: SuiEvent) {
    const data = event.parsedJson as Record<string, unknown>;
    const updatedAt = event.timestampMs ? new Date(Number(event.timestampMs)).toISOString() : new Date().toISOString();

    if (event.type.endsWith('::events::IntentCreatedEvent')) {
      const intent: IntentSnapshot = {
        intentId: required(data.intent_id ?? data.intentId, 'intent_id'),
        owner: required(data.owner, 'owner'),
        sellType: required(data.sell_type ?? data.sellType, 'sell_type'),
        buyType: required(data.buy_type ?? data.buyType, 'buy_type'),
        sellAmount: required(data.sell_amount ?? data.sellAmount, 'sell_amount'),
        minAmountOut: required(data.min_amount_out ?? data.minAmountOut, 'min_amount_out'),
        targetEpoch: required(data.target_epoch ?? data.targetEpoch, 'target_epoch'),
        deadline: required(data.deadline, 'deadline'),
        status: 'open',
        updatedAt,
      };
      await this.#store.upsertIntent(intent);
      return;
    }

    if (event.type.endsWith('::events::IntentUpdatedEvent')) {
      await this.#store.patchIntent(required(data.intent_id ?? data.intentId, 'intent_id'), {
        minAmountOut: required(data.new_min_amount_out ?? data.newMinAmountOut, 'new_min_amount_out'),
        targetEpoch: required(data.target_epoch ?? data.targetEpoch, 'target_epoch'),
        deadline: required(data.new_deadline ?? data.newDeadline, 'new_deadline'),
        updatedAt,
      });
      return;
    }

    if (event.type.endsWith('::events::IntentCancelledEvent')) {
      await this.#store.patchIntent(required(data.intent_id ?? data.intentId, 'intent_id'), {
        status: 'cancelled',
        updatedAt,
      });
      return;
    }

    if (event.type.endsWith('::events::SettlementEvent')) {
      await this.#store.patchIntent(required(data.intent_id ?? data.intentId, 'intent_id'), {
        status: 'settled',
        updatedAt,
      });
    }
  }
}

function required(value: unknown, key: string) {
  const text = valueOf(value);
  if (!text) throw new Error(`event missing ${key}`);
  return text;
}

function valueOf(value: unknown): string | undefined {
  if (value == null) return undefined;
  if (typeof value === 'object') {
    if ('id' in value) return valueOf((value as { id: unknown }).id);
    if ('name' in value) return valueOf((value as { name: unknown }).name);
    if ('bytes' in value) {
      const bytes = (value as { bytes: unknown }).bytes;
      if (Array.isArray(bytes)) return decoder.decode(Uint8Array.from(bytes));
      return valueOf(bytes);
    }
  }
  return String(value);
}
