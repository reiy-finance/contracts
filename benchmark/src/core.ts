import { Transaction } from '@mysten/sui/transactions';
import type { SuiGrpcClient } from '@mysten/sui/grpc';
import type { Keypair } from '@mysten/sui/cryptography';
import { estimateFee, signatureBytes, solutionIdBytes } from './certificate.ts';
import { eventData, executeTx, findEvent } from './execute.ts';
import type {
  BenchEnv,
  Direction,
  IntentPlan,
  IntentRecord,
  SettlementBatchRecord,
  SolutionCertificate,
  SolutionPlan,
  SolverStake,
} from './types.ts';

const decoder = new TextDecoder();

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

export type SolutionOptions = {
  solver: string;
  chunkSize: number;
  grossPayoutBps: bigint;
  expiresInMs: number;
  runId: string;
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
  const fallbackSell = plan.direction === 'base_to_quote' ? plan.baseType : plan.quoteType;
  const fallbackBuy = plan.direction === 'base_to_quote' ? plan.quoteType : plan.baseType;

  return {
    ...record,
    intentId: valueOf(data.intent_id ?? data.intentId),
    sellType: typeTag(valueOf(data.sell_type ?? data.sellType) ?? fallbackSell),
    buyType: typeTag(valueOf(data.buy_type ?? data.buyType) ?? fallbackBuy),
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

export function makeSolutionPlans(intentRecords: IntentRecord[], options: SolutionOptions): SolutionPlan[] {
  const usable = intentRecords.filter(
    (record) =>
      record.status === 'success' &&
      record.intentId &&
      record.sellType &&
      record.buyType &&
      record.sellAmount &&
      record.minAmountOut &&
      record.targetEpoch,
  );
  const groups = new Map<string, IntentRecord[]>();
  for (const record of usable) {
    const normalized = {
      ...record,
      sellType: typeTag(record.sellType)!,
      buyType: typeTag(record.buyType)!,
    };
    const key = `${normalized.targetEpoch}|${normalized.sellType}|${normalized.buyType}`;
    const group = groups.get(key) ?? [];
    group.push(normalized);
    groups.set(key, group);
  }

  const plans: SolutionPlan[] = [];
  for (const rows of groups.values()) {
    for (let i = 0; i < rows.length; i += options.chunkSize) {
      const chunk = rows.slice(i, i + options.chunkSize);
      const protectedMins = chunk.map((record) => BigInt(record.minAmountOut!));
      const grossPayouts = protectedMins.map((amount) => {
        const gross = (amount * options.grossPayoutBps) / 10000n;
        return gross > amount ? gross : amount + 1n;
      });
      const index = plans.length + 1;
      plans.push({
        index,
        solutionId: `${options.runId}-${index}`,
        solver: options.solver,
        sellType: chunk[0]!.sellType!,
        buyType: chunk[0]!.buyType!,
        epoch: chunk[0]!.targetEpoch!,
        intentIds: chunk.map((record) => record.intentId!),
        fills: chunk.map((record) => record.sellAmount),
        grossPayouts: grossPayouts.map(String),
        protectedMins: protectedMins.map(String),
        expiresAtMs: String(Date.now() + options.expiresInMs),
      });
    }
  }
  return plans;
}

export async function settleSolution(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  certificate: SolutionCertificate,
): Promise<SettlementBatchRecord> {
  const tx = buildSettleSolutionTx(env, certificate);
  const { record } = await executeTx(client, keypair, env, tx, 'settle_solution', certificate.index);
  const gross = sum(certificate.grossPayouts);
  const protectedMin = sum(certificate.protectedMins);
  const fee = certificate.grossPayouts.reduce(
    (acc, grossValue, index) => {
      const row = estimateFee(BigInt(grossValue), BigInt(certificate.protectedMins[index]!));
      acc.protocolFee += row.protocolFee;
      acc.solverFee += row.solverFee;
      return acc;
    },
    { protocolFee: 0n, solverFee: 0n },
  );

  return {
    ...record,
    solutionId: certificate.solutionId,
    intentCount: certificate.intentIds.length,
    grossPayoutMist: gross.toString(),
    protectedMinMist: protectedMin.toString(),
    estimatedProtocolFeeMist: fee.protocolFee.toString(),
    estimatedSolverFeeMist: fee.solverFee.toString(),
  };
}

export function buildSettleSolutionTx(env: BenchEnv, certificate: SolutionCertificate) {
  const tx = new Transaction();
  const [auth] = tx.moveCall({
    target: `${env.packageId}::settlement::verify_solution`,
    typeArguments: [certificate.sellType, certificate.buyType],
    arguments: [
      tx.object(env.auctionStateId),
      tx.object(env.globalConfigId),
      tx.pure.vector('u8', solutionIdBytes(certificate.solutionId)),
      tx.pure.address(certificate.solver),
      tx.pure.vector('address', certificate.intentIds),
      tx.pure.vector('u64', certificate.fills),
      tx.pure.vector('u64', certificate.grossPayouts),
      tx.pure.vector('u64', certificate.protectedMins),
      tx.pure.u64(certificate.expiresAtMs),
      tx.pure.vector('u8', signatureBytes(certificate)),
      tx.object(env.clockId),
    ],
  });

  for (let i = 0; i < certificate.intentIds.length; i += 1) {
    const [sellCoin, receipt] = tx.moveCall({
      target: `${env.packageId}::settlement::take_authorized_intent_full`,
      typeArguments: [certificate.sellType, certificate.buyType],
      arguments: [tx.object(env.auctionStateId), auth, tx.object(certificate.intentIds[i]!), tx.object(env.clockId)],
    });
    tx.transferObjects([sellCoin], tx.pure.address(certificate.solver));
    const payout = tx.coin({ type: certificate.buyType, balance: BigInt(certificate.grossPayouts[i]!) });
    tx.moveCall({
      target: `${env.packageId}::settlement::settle_intent_numeraire`,
      typeArguments: [certificate.sellType, certificate.buyType, env.stakeType],
      arguments: [
        tx.object(env.auctionStateId),
        tx.object(env.solverRegistryId),
        tx.object(env.globalConfigId),
        tx.object(env.feeVaultId),
        receipt,
        payout,
      ],
    });
  }

  return tx;
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
  for (const fn of ['stake_of', 'available_stake_of']) {
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
    available: commandU64(result, 1).toString(),
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
  if (typeof value === 'object') {
    if ('id' in value) return String((value as { id: unknown }).id);
    if ('name' in value) return valueOf((value as { name: unknown }).name);
    if ('bytes' in value) {
      const bytes = (value as { bytes: unknown }).bytes;
      if (Array.isArray(bytes)) return decoder.decode(Uint8Array.from(bytes));
      return valueOf(bytes);
    }
  }
  return String(value);
}

function typeTag(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const parts = value.split('::');
  if (parts.length < 3) return value;
  const address = parts[0]!.startsWith('0x') ? parts[0]! : `0x${parts[0]}`;
  return [address, ...parts.slice(1)].join('::');
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

function sum(values: string[]) {
  return values.reduce((acc, value) => acc + BigInt(value), 0n);
}

function lcg(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (1664525 * state + 1013904223) >>> 0;
    return state / 0xffffffff;
  };
}
