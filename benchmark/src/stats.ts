import type { SettlementBatchRecord, SettlementBatchSummary, Stats, Summary, TxRecord } from './types.ts';

export function summarize(op: string, records: TxRecord[], wallMs: number): Summary {
  const success = records.filter((r) => r.status === 'success').length;
  const failed = records.length - success;
  const errors: Record<string, number> = {};
  for (const record of records) {
    if (record.error) errors[record.error] = (errors[record.error] ?? 0) + 1;
  }
  return {
    op,
    count: records.length,
    success,
    failed,
    wallMs,
    throughputPerSec: wallMs > 0 ? (success * 1000) / wallMs : 0,
    latencyMs: stats(records.map((r) => r.latencyMs)),
    gasMist: stats(records.map(netGasMist).filter((n): n is number => n != null)),
    errors,
  };
}

export function summarizeByOp(records: TxRecord[], wallMs: number): Record<string, Summary> {
  const groups = new Map<string, TxRecord[]>();
  for (const record of records) {
    const group = groups.get(record.op) ?? [];
    group.push(record);
    groups.set(record.op, group);
  }
  return Object.fromEntries([...groups.entries()].map(([op, rows]) => [op, summarize(op, rows, wallMs)]));
}

export function summarizeSettlementBatches(records: SettlementBatchRecord[]): SettlementBatchSummary {
  const success = records.filter((record) => record.status === 'success' && record.intentCount > 0);
  return {
    op: 'settle_solution_batch',
    batches: success.length,
    intents: success.reduce((sum, record) => sum + record.intentCount, 0),
    batchSize: stats(success.map((record) => record.intentCount)),
    latencyPerIntentMs: stats(success.map((record) => record.latencyMs / record.intentCount)),
    gasPerIntentMist: stats(success.map((record) => (netGasMist(record) ?? 0) / record.intentCount)),
    protocolFeePerIntentMist: stats(success.map((record) => Number(record.estimatedProtocolFeeMist) / record.intentCount)),
    solverFeePerIntentMist: stats(success.map((record) => Number(record.estimatedSolverFeeMist) / record.intentCount)),
  };
}

export function stats(values: number[]): Stats {
  if (values.length === 0) return { min: 0, max: 0, avg: 0, p50: 0, p90: 0, p99: 0, sum: 0 };
  const sorted = values.toSorted((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  return {
    min: sorted[0]!,
    max: sorted[sorted.length - 1]!,
    avg: sum / sorted.length,
    p50: percentile(sorted, 0.5),
    p90: percentile(sorted, 0.9),
    p99: percentile(sorted, 0.99),
    sum,
  };
}

function percentile(sorted: number[], p: number) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1);
  return sorted[idx]!;
}

function netGasMist(record: TxRecord): number | undefined {
  if (record.gasMist != null) return Number(record.gasMist);
  if (record.computationCost == null && record.storageCost == null && record.storageRebate == null) return undefined;
  return Number(BigInt(record.computationCost ?? 0) + BigInt(record.storageCost ?? 0) - BigInt(record.storageRebate ?? 0));
}
