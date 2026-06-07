import { join } from 'node:path';
import { createClient, loadCoordinatorKeypair, loadKeypair } from './client.ts';
import {
  getBigInt,
  getBool,
  getDirection,
  getInt,
  getSettlementChunkConfig,
  loadBenchEnv,
  publicEnv,
  requireReadyForSettlement,
} from './env.ts';
import {
  makeIntentPlans,
  makeSolutionPlans,
  readSolverStake,
  registerSolver,
  settleSolution,
  submitIntent,
  topUpStake,
} from './core.ts';
import { signSolutionCertificate } from './certificate.ts';
import { createRunDir, writeJson, writeRun, type RunFile } from './report.ts';
import { summarize, summarizeByOp, summarizeSettlementBatches } from './stats.ts';
import type { IntentRecord, SettlementBatchRecord, TxRecord } from './types.ts';

const env = loadBenchEnv();
requireReadyForSettlement(env);
const minE2eGasBudget = getBigInt('E2E_GAS_BUDGET', 2_000_000_000n);
if (env.gasBudget < minE2eGasBudget) env.gasBudget = minE2eGasBudget;

const client = createClient(env);
const keypair = await loadKeypair();
const coordinator = await loadCoordinatorKeypair();
const { runId, runDir } = createRunDir(env.reportsDir, 'e2e');

const count = getInt('COUNT', getInt('BENCH_COUNT', 100));
const chunk = getSettlementChunkConfig();
const autoRegister = getBool('AUTO_REGISTER', true);
const autoTopUp = getBool('AUTO_TOP_UP', true);
const stakeAmount = getBigInt('STAKE_AMOUNT', 2_000_000_000n);
const grossPayoutBps = BigInt(getInt('GROSS_PAYOUT_BPS', 10_100));

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
const settlementRecords: SettlementBatchRecord[] = [];
const certificates = [];

console.log(`run: ${runId}`);
console.log(`signer: ${keypair.toSuiAddress()}`);
console.log(`coordinator: ${coordinator.toSuiAddress()}`);
console.log(`package: ${env.packageId}`);
console.log(`intents: ${count}`);
console.log(`settlement chunk size: ${chunk.effective}${chunk.capped ? ` (capped from ${chunk.requested})` : ''}`);

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

await writeJson(join(runDir, 'plan.json'), { intents: intentPlans, settlementChunk: chunk });

for (const plan of intentPlans) {
  const record = await submitIntent(client, keypair, env, plan);
  intentRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(`[intent ${record.index}/${intentPlans.length}] ${record.status} ${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'} ${record.intentId ?? record.error ?? ''}`);
}

if (autoTopUp) {
  const stake = await readSolverStake(client, keypair, env).catch((error) => {
    console.log(`[stake] read failed ${error instanceof Error ? error.message : String(error)}`);
    return null;
  });
  if (stake && BigInt(stake.available) < stakeAmount) {
    const deficit = stakeAmount - BigInt(stake.available);
    const { record } = await topUpStake(client, keypair, env, deficit);
    records.push(record);
    await writeJson(join(runDir, 'records.json'), records);
    console.log(`[top_up_stake] ${record.status} amount=${deficit} gas=${record.gasMist ?? '-'} ${record.error ?? ''}`);
  }
}

const solutionPlans = makeSolutionPlans(intentRecords, {
  solver: keypair.toSuiAddress(),
  chunkSize: chunk.effective,
  grossPayoutBps,
  expiresInMs: getInt('SOLUTION_TTL_MS', 300_000),
  runId,
});
await writeJson(join(runDir, 'plan.json'), { intents: intentPlans, solutions: solutionPlans, settlementChunk: chunk });

for (const plan of solutionPlans) {
  const signStart = performance.now();
  const certificate = await signSolutionCertificate(env, coordinator, plan);
  records.push({
    index: plan.index,
    op: 'coordinator_sign_solution',
    status: 'success',
    latencyMs: performance.now() - signStart,
  });
  certificates.push(certificate);
  await writeJson(join(runDir, 'certificates.json'), certificates);

  const record = await settleSolution(client, keypair, env, certificate);
  settlementRecords.push(record);
  records.push(record);
  await writeJson(join(runDir, 'records.json'), records);
  console.log(
    `[settle ${record.index}/${solutionPlans.length}] ${record.status} intents=${record.intentCount} ` +
      `${record.latencyMs.toFixed(0)}ms gas=${record.gasMist ?? '-'} ${record.digest ?? record.error ?? ''}`,
  );
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
    solutions: solutionPlans,
    settlementChunk: chunk,
    grossPayoutBps: grossPayoutBps.toString(),
  },
  records,
  summary: summarize('e2e', records, wallMs),
  summaries: summarizeByOp(records, wallMs),
  settlementBatchSummary: summarizeSettlementBatches(settlementRecords),
};

await writeRun(runDir, run);
console.log(`summary: ${join(runDir, 'summary.json')}`);
console.log(`figures: ${join(runDir, 'figures')}`);
