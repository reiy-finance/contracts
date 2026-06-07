import { join } from 'node:path';
import { createClient, loadCoordinatorKeypair, loadKeypair } from './client.ts';
import {
  getBigInt,
  getBool,
  getInt,
  getSettlementChunkConfig,
  loadBenchEnv,
  publicEnv,
  requireReadyForSettlement,
} from './env.ts';
import { makeSolutionPlans, readSolverStake, settleSolution, topUpStake } from './core.ts';
import { signSolutionCertificate } from './certificate.ts';
import { createRunDir, latestRun, readRun, writeJson, writeRun, type RunFile } from './report.ts';
import { summarize, summarizeByOp, summarizeSettlementBatches } from './stats.ts';
import type { IntentRecord, SettlementBatchRecord, TxRecord } from './types.ts';

const env = loadBenchEnv();
requireReadyForSettlement(env);

const client = createClient(env);
const keypair = await loadKeypair();
const coordinator = await loadCoordinatorKeypair();
const intentsRunPath = process.env.INTENTS_RUN ?? latestRun(env.reportsDir, 'intents');
const intentsRun = readRun<IntentRecord>(intentsRunPath);
const { runId, runDir } = createRunDir(env.reportsDir, 'settlements');

const chunk = getSettlementChunkConfig();
const autoTopUp = getBool('AUTO_TOP_UP', true);
const minStake = getBigInt('MIN_SETTLEMENT_STAKE', 1_000_000_000n);
const plans = makeSolutionPlans(intentsRun.records, {
  solver: keypair.toSuiAddress(),
  chunkSize: chunk.effective,
  grossPayoutBps: BigInt(getInt('GROSS_PAYOUT_BPS', 10_100)),
  expiresInMs: getInt('SOLUTION_TTL_MS', 300_000),
  runId,
});

await writeJson(join(runDir, 'plan.json'), { source: intentsRunPath, solutions: plans, settlementChunk: chunk });

const startedAt = new Date();
const records: TxRecord[] = [];
const settlementRecords: SettlementBatchRecord[] = [];

console.log(`run: ${runId}`);
console.log(`signer: ${keypair.toSuiAddress()}`);
console.log(`coordinator: ${coordinator.toSuiAddress()}`);
console.log(`intents: ${intentsRunPath}`);
console.log(`settlement batches: ${plans.length}`);
console.log(`settlement chunk size: ${chunk.effective}${chunk.capped ? ` (capped from ${chunk.requested})` : ''}`);

if (autoTopUp && plans.length > 0) {
  const stake = await readSolverStake(client, keypair, env).catch((error) => {
    console.log(`[stake] read failed ${error instanceof Error ? error.message : String(error)}`);
    return null;
  });
  if (stake) {
    const available = BigInt(stake.available);
    console.log(`[stake] total=${stake.stake} available=${stake.available} required=${minStake}`);
    if (available < minStake) {
      const deficit = minStake - available;
      const { record } = await topUpStake(client, keypair, env, deficit);
      records.push(record);
      await writeJson(join(runDir, 'records.json'), records);
      console.log(`[top_up_stake] ${record.status} amount=${deficit} gas=${record.gasMist ?? '-'} ${record.error ?? ''}`);
    }
  }
}

const certificates = [];
for (const plan of plans) {
  const signStart = performance.now();
  const certificate = await signSolutionCertificate(env, coordinator, plan);
  const signRecord: TxRecord = {
    index: plan.index,
    op: 'coordinator_sign_solution',
    status: 'success',
    latencyMs: performance.now() - signStart,
  };
  records.push(signRecord);
  certificates.push(certificate);
  await writeJson(join(runDir, 'certificates.json'), certificates);
  await writeJson(join(runDir, 'records.json'), records);

  const record = await settleSolution(client, keypair, env, certificate);
  settlementRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(
    `[settle ${record.index}/${plans.length}] ${record.status} intents=${record.intentCount} ` +
      `${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'} ${record.digest ?? record.error ?? ''}`,
  );
}

const finishedAt = new Date();
const summary = summarize('settlements', records, finishedAt.getTime() - startedAt.getTime());
const run: RunFile<TxRecord> = {
  runId,
  kind: 'settlements',
  startedAt: startedAt.toISOString(),
  finishedAt: finishedAt.toISOString(),
  env: { ...publicEnv(env), intentsRunPath },
  plans: { source: intentsRunPath, solutions: plans, settlementChunk: chunk },
  records,
  summary,
  summaries: summarizeByOp(records, finishedAt.getTime() - startedAt.getTime()),
  settlementBatchSummary: summarizeSettlementBatches(settlementRecords),
};

await writeRun(runDir, run);
console.log(`summary: ${join(runDir, 'summary.json')}`);
console.log(`figures: ${join(runDir, 'figures')}`);
