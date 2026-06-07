import { Transaction } from '@mysten/sui/transactions';
import type { SuiGrpcClient } from '@mysten/sui/grpc';
import type { Keypair } from '@mysten/sui/cryptography';
import { eventData, executeTx, findEvent } from './execute.ts';
import type { BenchEnv, BidPlan, BidRecord, Direction, IntentPlan, IntentRecord, SelectionRecord, SolverStake } from './types.ts';

export type IntentOptions = {
  count: number;
  direction: Direction;
  sellAmount: bigint;
  sellJitterBps: number;
  slippageBps: number;
  ttlMs: number;
  partialFillable: boolean;
  seed: number;
};

export function makeIntentPlans(env: BenchEnv, options: IntentOptions): IntentPlan[] {
  const rand = lcg(options.seed);
  const now = BigInt(Date.now());
  const plans: IntentPlan[] = [];
  for (let i = 0; i < options.count; i += 1) {
    const jitter = options.sellJitterBps > 0 ? BigInt(Math.floor(rand() * options.sellJitterBps)) : 0n;
    const sign = rand() > 0.5 ? 1n : -1n;
    const sellAmount = options.sellAmount + (options.sellAmount * jitter * sign) / 10000n;
    const deadline = now + BigInt(options.ttlMs + i * 250);
    plans.push({
      index: i + 1,
      direction: options.direction,
      baseType: env.baseType,
      quoteType: env.quoteType,
      poolId: env.poolId,
      sellAmount: sellAmount > 0n ? sellAmount.toString() : options.sellAmount.toString(),
      slippageBps: options.slippageBps,
      partialFillable: options.partialFillable,
      ttlMs: options.ttlMs,
      deadline: deadline.toString(),
    });
  }
  return plans;
}

export async function submitIntent(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  plan: IntentPlan,
): Promise<IntentRecord> {
  const tx = buildSubmitIntentTx(env, plan);
  const { record, result } = await executeTx(client, keypair, env, tx, 'submit_intent', plan.index);
  const event = findEvent(result, '::events::IntentCreatedEvent');
  const data = event ? eventData(event) : {};

  return {
    ...record,
    intentId: valueOf(data.intent_id ?? data.intentId),
    sellType: valueOf(data.sell_type ?? data.sellType),
    buyType: valueOf(data.buy_type ?? data.buyType),
    sellAmount: valueOf(data.sell_amount ?? data.sellAmount) ?? plan.sellAmount,
    minAmountOut: valueOf(data.min_amount_out ?? data.minAmountOut),
    sbboFloor: valueOf(data.sbbo_floor ?? data.sbboFloor),
    sbboMidPrice: valueOf(data.sbbo_mid_price ?? data.sbboMidPrice),
    targetEpoch: valueOf(data.target_epoch ?? data.targetEpoch),
    deadline: valueOf(data.deadline) ?? plan.deadline,
  };
}

export function buildSubmitIntentTx(env: BenchEnv, plan: IntentPlan) {
  const tx = new Transaction();
  maybeRefreshDeepBook(tx, env);

  const [midPrice] = tx.moveCall({
    target: `${env.packageId}::price_adapter::read_mid_price`,
    typeArguments: [plan.baseType, plan.quoteType],
    arguments: [tx.object(plan.poolId), tx.object(env.globalConfigId), tx.object(env.clockId)],
  });

  const [minAmountOut] = tx.moveCall({
    target:
      plan.direction === 'base_to_quote'
        ? `${env.packageId}::price_adapter::sbbo_floor_base_to_quote`
        : `${env.packageId}::price_adapter::sbbo_floor_quote_to_base`,
    arguments: [tx.pure.u64(plan.sellAmount), midPrice, tx.pure.u64(plan.slippageBps)],
  });

  const sellType = plan.direction === 'base_to_quote' ? plan.baseType : plan.quoteType;
  const sellCoin = tx.coin({ type: sellType, balance: BigInt(plan.sellAmount) });
  const target =
    plan.direction === 'base_to_quote'
      ? `${env.packageId}::auction::submit_intent_sell_base`
      : `${env.packageId}::auction::submit_intent_sell_quote`;

  tx.moveCall({
    target,
    typeArguments: [plan.baseType, plan.quoteType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.globalConfigId),
      tx.object(plan.poolId),
      sellCoin,
      minAmountOut,
      tx.pure.u64(plan.slippageBps),
      tx.pure.bool(plan.partialFillable),
      tx.pure.u64(plan.deadline),
      tx.object(env.clockId),
    ],
  });

  return tx;
}

export async function advancePhase(client: SuiGrpcClient, keypair: Keypair, env: BenchEnv, index = 1) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${env.packageId}::auction::advance_phase`,
    typeArguments: [env.stakeType],
    arguments: [tx.object(env.auctionStateId), tx.object(env.solverRegistryId), tx.object(env.globalConfigId), tx.object(env.clockId)],
  });
  return executeTx(client, keypair, env, tx, 'advance_phase', index);
}

export async function triggerFallback(client: SuiGrpcClient, keypair: Keypair, env: BenchEnv, index = 1) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${env.packageId}::settlement::trigger_fallback`,
    typeArguments: [env.quoteType, env.stakeType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.solverRegistryId),
      tx.object(env.globalConfigId),
      tx.object(env.protocolTreasuryId),
      tx.object(env.clockId),
    ],
  });
  return executeTx(client, keypair, env, tx, 'trigger_fallback', index);
}

export async function registerSolver(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  stakeAmount: bigint,
  url: string,
) {
  const tx = new Transaction();
  const stake = tx.coin({ type: env.stakeType, balance: stakeAmount });
  tx.moveCall({
    target: `${env.packageId}::solver_registry::register_solver`,
    typeArguments: [env.stakeType],
    arguments: [
      tx.object(env.solverRegistryId),
      tx.object(env.globalConfigId),
      stake,
      tx.pure.vector('u8', [...new TextEncoder().encode(url)]),
    ],
  });
  return executeTx(client, keypair, env, tx, 'register_solver', 1);
}

export async function topUpStake(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  amount: bigint,
  index = 1,
) {
  const tx = new Transaction();
  const stake = tx.coin({ type: env.stakeType, balance: amount });
  tx.moveCall({
    target: `${env.packageId}::solver_registry::top_up_stake`,
    typeArguments: [env.stakeType],
    arguments: [tx.object(env.solverRegistryId), stake],
  });
  return executeTx(client, keypair, env, tx, 'top_up_stake', index);
}

export async function readSolverStake(client: SuiGrpcClient, keypair: Keypair, env: BenchEnv): Promise<SolverStake> {
  const tx = new Transaction();
  const solver = keypair.toSuiAddress();
  tx.setSender(solver);
  for (const fn of ['stake_of', 'reserved_stake_of', 'available_stake_of']) {
    tx.moveCall({
      target: `${env.packageId}::solver_registry::${fn}`,
      typeArguments: [env.stakeType],
      arguments: [tx.object(env.solverRegistryId), tx.pure.address(solver)],
    });
  }
  const result = await (client as any).core.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
    checksEnabled: false,
  });
  return {
    stake: commandU64(result, 0).toString(),
    reserved: commandU64(result, 1).toString(),
    available: commandU64(result, 2).toString(),
  };
}

export function makeBidPlans(intentRecords: IntentRecord[], chunkSize: number, payoutMultiplier: bigint): BidPlan[] {
  const usable = intentRecords.filter((record) => record.status === 'success' && record.intentId && record.minAmountOut);
  const plans: BidPlan[] = [];
  const size = Math.max(1, Math.floor(chunkSize));
  for (let i = 0; i < usable.length; i += size) {
    const chunk = usable.slice(i, i + size);
    const fills = chunk.map((record) => record.sellAmount);
    const minAmounts = chunk.map((record) => BigInt(record.minAmountOut!));
    const payouts = minAmounts.map((amount) => amount * payoutMultiplier);
    const score = payouts.reduce((sum, payout, idx) => sum + (payout - minAmounts[idx]!), 0n);
    plans.push({
      index: plans.length + 1,
      intentIds: chunk.map((record) => record.intentId!),
      fills,
      payouts: payouts.map((value) => value.toString()),
      declaredMulti: distinctPairs(chunk) > 1,
      score: score.toString(),
    });
  }
  return plans;
}

export async function submitBid(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  plan: BidPlan,
): Promise<BidRecord> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${env.packageId}::auction::submit_bid`,
    typeArguments: [env.stakeType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.solverRegistryId),
      tx.object(env.globalConfigId),
      tx.pure.vector('address', plan.intentIds),
      tx.pure.vector('u64', plan.fills),
      tx.pure.vector('u64', plan.payouts),
      tx.pure.bool(plan.declaredMulti),
      tx.pure.u64(plan.score),
    ],
  });

  const { record, result } = await executeTx(client, keypair, env, tx, 'submit_bid', plan.index);
  const event = findEvent(result, '::events::BidSubmittedEvent');
  const data = event ? eventData(event) : {};

  return {
    ...record,
    bidSeq: valueOf(data.bid_seq ?? data.bidSeq),
    intentCount: Number(valueOf(data.intent_count ?? data.intentCount) ?? plan.intentIds.length),
    score: valueOf(data.score) ?? plan.score,
    stakeReserved: valueOf(data.stake_reserved ?? data.stakeReserved),
  };
}

export async function submitPairBenchmark(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  bidSeqs: string[],
  index = 1,
): Promise<SelectionRecord> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${env.packageId}::auction::submit_pair_benchmark`,
    typeArguments: [env.stakeType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.solverRegistryId),
      tx.object(env.globalConfigId),
      tx.pure.vector('u64', bidSeqs),
    ],
  });
  const { record, result } = await executeTx(client, keypair, env, tx, 'submit_pair_benchmark', index);
  const event = findEvent(result, '::events::PairBenchmarkSubmittedEvent');
  const data = event ? eventData(event) : {};
  return {
    ...record,
    bidSeqs,
    totalScore: valueOf(data.total_score ?? data.totalScore),
    bidCount: Number(valueOf(data.bid_count ?? data.bidCount) ?? bidSeqs.length),
  };
}

export async function submitAllocation(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  bidSeqs: string[],
  totalScore: string,
  index = 1,
): Promise<SelectionRecord> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${env.packageId}::auction::submit_allocation`,
    typeArguments: [env.stakeType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.solverRegistryId),
      tx.object(env.globalConfigId),
      tx.pure.vector('u64', bidSeqs),
      tx.pure.u64(totalScore),
    ],
  });
  const { record, result } = await executeTx(client, keypair, env, tx, 'submit_allocation', index);
  const event = findEvent(result, '::events::AllocationSubmittedEvent');
  const data = event ? eventData(event) : {};
  return {
    ...record,
    bidSeqs,
    totalScore: valueOf(data.total_score ?? data.totalScore) ?? totalScore,
    bidCount: Number(valueOf(data.bid_count ?? data.bidCount) ?? bidSeqs.length),
  };
}

function maybeRefreshDeepBook(tx: Transaction, env: BenchEnv) {
  if (process.env.REFRESH_DEEPBOOK === '0') return;
  if (!env.deepbookPackageId || !env.deepbookRegistryId) return;
  tx.moveCall({
    target: `${env.deepbookPackageId}::pool::update_pool_allowed_versions`,
    typeArguments: [env.baseType, env.quoteType],
    arguments: [tx.object(env.poolId), tx.object(env.deepbookRegistryId)],
  });
}

function valueOf(value: unknown): string | undefined {
  if (value == null) return undefined;
  if (typeof value === 'object' && 'id' in value) return String((value as { id: unknown }).id);
  return String(value);
}

function commandU64(result: any, commandIndex: number) {
  const bytes = result?.commandResults?.[commandIndex]?.returnValues?.[0]?.bcs;
  if (!bytes) return 0n;
  const data = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes);
  if (data.length < 8) return 0n;
  let value = 0n;
  for (let i = 0; i < 8; i += 1) value += BigInt(data[i]!) << BigInt(i * 8);
  return value;
}

function lcg(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (1664525 * state + 1013904223) >>> 0;
    return state / 0xffffffff;
  };
}

function distinctPairs(records: IntentRecord[]) {
  return new Set(records.map((record) => `${record.sellType ?? ''}->${record.buyType ?? ''}`)).size;
}
