import { existsSync, readFileSync } from 'node:fs';
import type { EventCursor, IntentSnapshot, SolutionCertificate, SolverQuote, StoreShape } from './types.ts';

export class JsonStore {
  #path: string;
  #data: StoreShape;

  constructor(path: string) {
    this.#path = path;
    const loaded = existsSync(path) ? (JSON.parse(readFileSync(path, 'utf8')) as Partial<StoreShape>) : {};
    this.#data = {
      intents: loaded.intents ?? [],
      quotes: loaded.quotes ?? [],
      certificates: loaded.certificates ?? [],
      indexer: loaded.indexer ?? { indexedEvents: 0 },
    };
  }

  all() {
    return this.#data;
  }

  orderbook(filters: { epoch?: string; sellType?: string; buyType?: string }) {
    return this.#data.intents.filter((intent) => {
      if (intent.status !== 'open') return false;
      if (filters.epoch && intent.targetEpoch !== filters.epoch) return false;
      if (filters.sellType && intent.sellType !== filters.sellType) return false;
      if (filters.buyType && intent.buyType !== filters.buyType) return false;
      return true;
    });
  }

  indexer() {
    return this.#data.indexer;
  }

  upsertIntent(intent: IntentSnapshot) {
    const idx = this.#data.intents.findIndex((row) => row.intentId === intent.intentId);
    if (idx >= 0) this.#data.intents[idx] = intent;
    else this.#data.intents.push(intent);
    return this.flush();
  }

  patchIntent(intentId: string, patch: Partial<IntentSnapshot>) {
    const idx = this.#data.intents.findIndex((row) => row.intentId === intentId);
    if (idx < 0) return this.flush();
    this.#data.intents[idx] = { ...this.#data.intents[idx]!, ...patch };
    return this.flush();
  }

  addQuote(quote: SolverQuote) {
    this.#data.quotes.push(quote);
    return this.flush();
  }

  addCertificate(certificate: SolutionCertificate) {
    this.#data.certificates.push(certificate);
    return this.flush();
  }

  setIndexerCursor(cursor: EventCursor, indexedDelta: number) {
    this.#data.indexer.cursor = cursor;
    this.#data.indexer.indexedEvents += indexedDelta;
    this.#data.indexer.lastSyncAt = new Date().toISOString();
    this.#data.indexer.lastError = undefined;
    return this.flush();
  }

  setIndexerError(error: string) {
    this.#data.indexer.lastError = error;
    this.#data.indexer.lastSyncAt = new Date().toISOString();
    return this.flush();
  }

  async flush() {
    await Bun.write(this.#path, JSON.stringify(this.#data, null, 2));
  }
}
