import { join } from 'node:path';
import { createClient, loadKeypair } from './client.ts';
import { getBidChunkConfig, getBigInt, getBool, getDirection, getInt, loadBenchEnv, publicEnv, requireReadyForBids } from './env.ts';
import {
  advancePhase,
  makeBidPlans,
  makeIntentPlans,
  readSolverStake,
  registerSolver,
  submitAllocation,
  submitBid,
  submitIntent,
  submitPairBenchmark,
  topUpStake,
} from './core.ts';
import { createRunDir, writeJson, writeRun, type RunFile } from './report.ts';
import { summarize, summarizeBidBatches, summarizeByOp } from './stats.ts';
import type { BidRecord, IntentRecord, SelectionRecord, TxRecord } from './types.ts';

const env = loadBenchEnv();
requireReadyForBids(env);
const minE2eGasBudget = getBigInt('E2E_GAS_BUDGET', 2_000_000_000n);
if (env.gasBudget < minE2eGasBudget) env.gasBudget = minE2eGasBudget;

const client = createClient(env);
const keypair = await loadKeypair();
const { runId, runDir } = createRunDir(env.reportsDir, 'e2e');

const count = getInt('COUNT', getInt('BENCH_COUNT', 100));
const bidChunk = getBidChunkConfig();
const bidChunkSize = bidChunk.effective;
const payoutMultiplier = BigInt(getInt('BID_PAYOUT_MULTIPLIER', 1));
const autoRegister = getBool('AUTO_REGISTER', true);
const fullSelection = getBool('FULL_SELECTION', true);
const bidWaitMs = getInt('BID_WAIT_MS', 5500);
const selectionWaitMs = getInt('SELECTION_WAIT_MS', 5500);
const stakeReserveUnit = getBigInt('STAKE_RESERVE_UNIT', 1_000_000_000n);
const estimatedReserveCount = BigInt(Math.ceil(count / bidChunkSize) + (fullSelection ? 2 : 0));
const estimatedStakeAmount = stakeReserveUnit * estimatedReserveCount;
const stakeAmount = getBigInt('STAKE_AMOUNT', estimatedStakeAmount);
const autoTopUp = getBool('AUTO_TOP_UP', true);

const intentPlans = makeIntentPlans(env, {
  count,
  direction: getDirection(),
  sellAmount: getBigInt('SELL_AMOUNT', 10_000_000n),
  sellJitterBps: getInt('SELL_JITTER_BPS', 0),
  slippageBps: getInt('SLIPPAGE_BPS', 500),
  ttlMs: getInt('TTL_MS', 3_600_000),
  partialFillable: getBool('PARTIAL_FILLABLE', false),
  seed: getInt('SEED', 42),
});

const startedAt = new Date();
const records: TxRecord[] = [];
const intentRecords: IntentRecord[] = [];
const bidRecords: BidRecord[] = [];
const selectionRecords: SelectionRecord[] = [];

console.log(`run: ${runId}`);
console.log(`signer: ${keypair.toSuiAddress()}`);
console.log(`package: ${env.packageId}`);
console.log(`intents: ${count}`);
console.log(`bid chunk size: ${bidChunkSize}${bidChunk.capped ? ` (capped from ${bidChunk.requested})` : ''}`);
console.log(`estimated stake needed: ${estimatedStakeAmount}`);

if (autoRegister) {
  const { record } = await registerSolver(client, keypair, env, stakeAmount, process.env.SOLVER_URL ?? 'benchmark://e2e');
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  if (record.status === 'failed') {
    console.log(`[register] skipped/failed ${record.error ?? ''}`);
  } else {
    console.log(`[register] success gas=${record.gasMist ?? '-'}`);
  }
}

await writeJson(join(runDir, 'plan.json'), { intents: intentPlans });

for (const plan of intentPlans) {
  const record = await submitIntent(client, keypair, env, plan);
  intentRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[intent ${record.index}/${intentPlans.length}] ${record.status} ${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'} ${record.intentId ?? record.error ?? ''}`);
}

let advance = await advancePhase(client, keypair, env, 1);
advance.record.op = 'advance_to_bid';
records.push(advance.record);
await writeJson(join(runDir, 'records.json'), records);
console.log(`[advance_to_bid] ${advance.record.status} ${advance.record.error ?? ''}`);

const bidPlans = makeBidPlans(intentRecords, bidChunkSize, payoutMultiplier);
await writeJson(join(runDir, 'plan.json'), { intents: intentPlans, bids: bidPlans, bidChunk });

if (autoTopUp && bidPlans.length > 0) {
  const requiredStake = stakeReserveUnit * BigInt(bidPlans.length + (fullSelection ? 2 : 0));
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

for (const plan of bidPlans) {
  const record = await submitBid(client, keypair, env, plan);
  bidRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[bid ${record.index}/${bidPlans.length}] ${record.status} intents=${record.intentCount} ${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'} ${record.bidSeq ?? record.error ?? ''}`);
}

if (fullSelection && bidPlans.length > 0) {
  console.log(`wait ${bidWaitMs}ms for bid window`);
  await Bun.sleep(bidWaitMs);

  advance = await advancePhase(client, keypair, env, 2);
  advance.record.op = 'advance_to_selection';
  records.push(advance.record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[advance_to_selection] ${advance.record.status} ${advance.record.error ?? ''}`);

  const bidSeqs = bidRecords.map((record, index) => record.bidSeq ?? String(index));
  const totalScore = bidPlans.reduce((sum, plan) => sum + BigInt(plan.score), 0n).toString();

  const benchmarkRecord = await submitPairBenchmark(client, keypair, env, bidSeqs, 1);
  selectionRecords.push(benchmarkRecord);
  records.push(benchmarkRecord);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[pair_benchmark] ${benchmarkRecord.status} bids=${benchmarkRecord.bidCount ?? bidSeqs.length} gas=${benchmarkRecord.gasMist ?? '-'} ${benchmarkRecord.error ?? ''}`);

  const allocationRecord = await submitAllocation(client, keypair, env, bidSeqs, totalScore, 1);
  selectionRecords.push(allocationRecord);
  records.push(allocationRecord);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[allocation] ${allocationRecord.status} bids=${allocationRecord.bidCount ?? bidSeqs.length} gas=${allocationRecord.gasMist ?? '-'} ${allocationRecord.error ?? ''}`);

  console.log(`wait ${selectionWaitMs}ms for selection window`);
  await Bun.sleep(selectionWaitMs);

  advance = await advancePhase(client, keypair, env, 3);
  advance.record.op = 'advance_to_settlement';
  records.push(advance.record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[advance_to_settlement] ${advance.record.status} ${advance.record.error ?? ''}`);
}

const finishedAt = new Date();
const wallMs = finishedAt.getTime() - startedAt.getTime();
const run: RunFile<TxRecord> = {
  runId,
  kind: 'e2e',
  startedAt: startedAt.toISOString(),
  finishedAt: finishedAt.toISOString(),
  env: publicEnv(env),
  plans: {
    intents: intentPlans,
    bids: bidPlans,
    bidChunk,
    fullSelection,
  },
  records,
  summary: summarize('e2e', records, wallMs),
  summaries: summarizeByOp(records, wallMs),
  bidBatchSummary: summarizeBidBatches(bidRecords),
};

await writeRun(runDir, run);
console.log(`summary: ${join(runDir, 'summary.json')}`);
console.log(`figures: ${join(runDir, 'figures')}`);
