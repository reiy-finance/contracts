import { join } from 'node:path';
import { createClient, loadKeypair } from './client.ts';
import { getBidChunkConfig, getBigInt, getBool, getInt, loadBenchEnv, publicEnv, requireReadyForBids } from './env.ts';
import { advancePhase, makeBidPlans, readSolverStake, submitBid, topUpStake } from './core.ts';
import { createRunDir, latestRun, readRun, writeJson, writeRun, type RunFile } from './report.ts';
import { summarize, summarizeBidBatches } from './stats.ts';
import type { BidRecord, IntentRecord, TxRecord } from './types.ts';

const env = loadBenchEnv();
requireReadyForBids(env);

const client = createClient(env);
const keypair = await loadKeypair();
const intentsRunPath = process.env.INTENTS_RUN ?? latestRun(env.reportsDir, 'intents');
const intentsRun = readRun<IntentRecord>(intentsRunPath);
const { runId, runDir } = createRunDir(env.reportsDir, 'bids');

if (getBool('ADVANCE', false)) {
  const { record } = await advancePhase(client, keypair, env, 0);
  console.log(`[advance] ${record.status} ${record.latencyMs.toFixed(0)}ms ${record.error ?? ''}`);
}

const bidChunk = getBidChunkConfig();
const plans = makeBidPlans(
  intentsRun.records,
  bidChunk.effective,
  BigInt(getInt('BID_PAYOUT_MULTIPLIER', 1)),
);
const stakeReserveUnit = getBigInt('STAKE_RESERVE_UNIT', 1_000_000_000n);
const autoTopUp = getBool('AUTO_TOP_UP', true);

await writeJson(join(runDir, 'plan.json'), { bids: plans, bidChunk });

const startedAt = new Date();
const records: TxRecord[] = [];
const bidRecords: BidRecord[] = [];

console.log(`run: ${runId}`);
console.log(`intents: ${intentsRunPath}`);
console.log(`bids: ${plans.length}`);
console.log(`bid chunk size: ${bidChunk.effective}${bidChunk.capped ? ` (capped from ${bidChunk.requested})` : ''}`);

if (autoTopUp && plans.length > 0) {
  const requiredStake = stakeReserveUnit * BigInt(plans.length);
  const stake = await readSolverStake(client, keypair, env).catch((error) => {
    console.log(`[stake] read failed ${error instanceof Error ? error.message : String(error)}`);
    return null;
  });
  if (stake) {
    const available = BigInt(stake.available);
    console.log(`[stake] total=${stake.stake} reserved=${stake.reserved} available=${stake.available} required=${requiredStake}`);
    if (available < requiredStake) {
      const deficit = requiredStake - available;
      const { record } = await topUpStake(client, keypair, env, deficit);
      records.push(record);
      await writeJson(join(runDir, 'records.json'), records);
      console.log(`[top_up_stake] ${record.status} amount=${deficit} gas=${record.gasMist ?? '-'} ${record.error ?? ''}`);
    }
  }
}

for (const plan of plans) {
  const record = await submitBid(client, keypair, env, plan);
  bidRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  const tail = record.bidSeq ? ` bid=${record.bidSeq}` : record.error ? ` error=${record.error}` : '';
  console.log(`[${record.index}/${plans.length}] ${record.status} intents=${record.intentCount} ${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'}${tail}`);
}

const finishedAt = new Date();
const summary = summarize('bids', records, finishedAt.getTime() - startedAt.getTime());
const run: RunFile<TxRecord> = {
  runId,
  kind: 'bids',
  startedAt: startedAt.toISOString(),
  finishedAt: finishedAt.toISOString(),
  env: { ...publicEnv(env), intentsRunPath },
  plans: { bids: plans, bidChunk },
  records,
  summary,
  bidBatchSummary: summarizeBidBatches(bidRecords),
};

await writeRun(runDir, run);
console.log(`summary: ${join(runDir, 'summary.json')}`);
console.log(`figures: ${join(runDir, 'figures')}`);
