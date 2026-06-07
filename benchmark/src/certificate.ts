import { bcs } from '@mysten/sui/bcs';
import type { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import type { BenchEnv, SolutionCertificate, SolutionPlan } from './types.ts';

const text = new TextEncoder();

const AsciiString = bcs.struct('AsciiString', {
  bytes: bcs.vector(bcs.u8()),
});

const TypeName = bcs.struct('TypeName', {
  name: AsciiString,
});

const SolutionMessage = bcs.struct('SolutionMessage', {
  protocol_state_id: bcs.Address,
  config_id: bcs.Address,
  key_version: bcs.u64(),
  epoch: bcs.u64(),
  solution_id: bcs.vector(bcs.u8()),
  solver: bcs.Address,
  sell_type: TypeName,
  buy_type: TypeName,
  intent_ids: bcs.vector(bcs.Address),
  fills: bcs.vector(bcs.u64()),
  gross_payouts: bcs.vector(bcs.u64()),
  protected_mins: bcs.vector(bcs.u64()),
  expires_at_ms: bcs.u64(),
});

export async function signSolutionCertificate(
  env: BenchEnv,
  coordinator: Ed25519Keypair,
  plan: SolutionPlan,
): Promise<SolutionCertificate> {
  const bytes = solutionMessageBytes(env, plan);
  const signature = await coordinator.sign(bytes);
  return {
    ...plan,
    signatureHex: toHex(signature),
    messageBcsHex: toHex(bytes),
  };
}

export function solutionMessageBytes(env: BenchEnv, plan: SolutionPlan): Uint8Array {
  return SolutionMessage.serialize({
    protocol_state_id: env.auctionStateId,
    config_id: env.globalConfigId,
    key_version: BigInt(env.coordinatorKeyVersion),
    epoch: BigInt(plan.epoch),
    solution_id: [...text.encode(plan.solutionId)],
    solver: plan.solver,
    sell_type: typeName(plan.sellType),
    buy_type: typeName(plan.buyType),
    intent_ids: plan.intentIds,
    fills: plan.fills.map(BigInt),
    gross_payouts: plan.grossPayouts.map(BigInt),
    protected_mins: plan.protectedMins.map(BigInt),
    expires_at_ms: BigInt(plan.expiresAtMs),
  }).toBytes();
}

export function solutionIdBytes(solutionId: string) {
  return [...text.encode(solutionId)];
}

export function signatureBytes(certificate: SolutionCertificate) {
  return [...fromHex(certificate.signatureHex)];
}

export function canonicalTypeName(type: string) {
  return type
    .split('::')
    .map((part, index) => (index === 0 ? strip0x(part).padStart(64, '0').toLowerCase() : part))
    .join('::');
}

export function estimateFee(gross: bigint, protectedMin: bigint, fee = defaultFeeConfig()) {
  const volumeFee = (gross * fee.volumeFeePpm) / 1_000_000n;
  const afterVolume = gross - volumeFee;
  const surplusAfterVolume = afterVolume > protectedMin ? afterVolume - protectedMin : 0n;
  const surplusByShare = (surplusAfterVolume * fee.surplusFeePpm) / 1_000_000n;
  const surplusByCap = (gross * fee.surplusFeeCapPpm) / 1_000_000n;
  const surplusFee = surplusByShare < surplusByCap ? surplusByShare : surplusByCap;
  const totalUncapped = volumeFee + surplusFee;
  const maxTotal = (gross * fee.maxTotalFeePpm) / 1_000_000n;
  const totalFee = totalUncapped < maxTotal ? totalUncapped : maxTotal;
  const solverFee = (totalFee * fee.solverFeeSharePpm) / 1_000_000n;
  return {
    volumeFee,
    surplusFee,
    totalFee,
    solverFee,
    protocolFee: totalFee - solverFee,
  };
}

export function defaultFeeConfig() {
  return {
    volumeFeePpm: BigInt(process.env.STANDARD_VOLUME_FEE_PPM ?? '75'),
    surplusFeePpm: BigInt(process.env.SURPLUS_FEE_PPM ?? '100000'),
    surplusFeeCapPpm: BigInt(process.env.SURPLUS_FEE_CAP_PPM ?? '1000'),
    maxTotalFeePpm: BigInt(process.env.MAX_TOTAL_FEE_PPM ?? '1500'),
    solverFeeSharePpm: BigInt(process.env.SOLVER_FEE_SHARE_PPM ?? '350000'),
  };
}

function typeName(type: string) {
  return { name: { bytes: [...text.encode(canonicalTypeName(type))] } };
}

function strip0x(value: string) {
  return value.startsWith('0x') ? value.slice(2) : value;
}

function toHex(bytes: Uint8Array | number[]) {
  return `0x${Buffer.from(bytes).toString('hex')}`;
}

function fromHex(value: string) {
  const hex = value.startsWith('0x') ? value.slice(2) : value;
  return Uint8Array.from(Buffer.from(hex, 'hex'));
}
