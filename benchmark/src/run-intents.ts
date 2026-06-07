import { join } from 'node:path';
import { createClient, loadKeypair } from './client.ts';
import { getBigInt, getBool, getDirection, getInt, loadBenchEnv, publicEnv } from './env.ts';
import { makeIntentPlans, submitIntent } from './core.ts';
import { createRunDir, writeJson, writeRun, type RunFile } from './report.ts';
import { summarize } from './stats.ts';
import type { IntentRecord } from './types.ts';

const env = loadBenchEnv();
const client = createClient(env);
const keypair = await loadKeypair();
const { runId, runDir } = createRunDir(env.reportsDir, 'intents');

const plans = makeIntentPlans(env, {
  count: getInt('COUNT', getInt('BENCH_COUNT', 100)),
  direction: getDirection(),
  sellAmount: getBigInt('SELL_AMOUNT', 10_000_000n),
  sellJitterBps: getInt('SELL_JITTER_BPS', 0),
  slippageBps: getInt('SLIPPAGE_BPS', 500),
  ttlMs: getInt('TTL_MS', 3_600_000),
  partialFillable: getBool('PARTIAL_FILLABLE', false),
  seed: getInt('SEED', 42),
});

await writeJson(join(runDir, 'plan.json'), plans);

const startedAt = new Date();
const records: IntentRecord[] = [];

console.log(`run: ${runId}`);
console.log(`signer: ${keypair.toSuiAddress()}`);
console.log(`count: ${plans.length}`);

for (const plan of plans) {
  const record = await submitIntent(client, keypair, env, plan);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  const tail = record.intentId ? ` intent=${record.intentId}` : record.error ? ` error=${record.error}` : '';
  console.log(`[${record.index}/${plans.length}] ${record.status} ${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'}${tail}`);
}

const finishedAt = new Date();
const summary = summarize('submit_intent', records, finishedAt.getTime() - startedAt.getTime());
const run: RunFile<IntentRecord> = {
  runId,
  kind: 'intents',
  startedAt: startedAt.toISOString(),
  finishedAt: finishedAt.toISOString(),
  env: publicEnv(env),
  plans,
  records,
  summary,
};

await writeRun(runDir, run);
console.log(`summary: ${join(runDir, 'summary.json')}`);
console.log(`figures: ${join(runDir, 'figures')}`);
