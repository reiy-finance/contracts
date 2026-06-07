import { bcs } from '@mysten/sui/bcs';
import type { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import type { CoordinatorConfig, SolutionCertificate, SolutionPlan } from './types.ts';

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

export async function signSolution(
  config: CoordinatorConfig,
  keypair: Ed25519Keypair,
  plan: SolutionPlan,
): Promise<SolutionCertificate> {
  assertSolution(plan);
  const bytes = messageBytes(config, plan);
  const signature = await keypair.sign(bytes);
  return { ...plan, signatureHex: hex(signature), messageBcsHex: hex(bytes) };
}

export function messageBytes(config: CoordinatorConfig, plan: SolutionPlan) {
  return SolutionMessage.serialize({
    protocol_state_id: config.auctionStateId,
    config_id: config.globalConfigId,
    key_version: BigInt(config.coordinatorKeyVersion),
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

export function publicKeyHex(keypair: Ed25519Keypair) {
  return hex(keypair.getPublicKey().toRawBytes());
}

function assertSolution(plan: SolutionPlan) {
  const n = plan.intentIds.length;
  if (!n) throw new Error('solution must include at least one intent');
  for (const key of ['fills', 'grossPayouts', 'protectedMins'] as const) {
    if (plan[key].length !== n) throw new Error(`${key} length mismatch`);
  }
}

function typeName(type: string) {
  return { name: { bytes: [...text.encode(canonicalTypeName(type))] } };
}

function canonicalTypeName(type: string) {
  return type
    .split('::')
    .map((part, index) => (index === 0 ? strip0x(part).padStart(64, '0').toLowerCase() : part))
    .join('::');
}

function strip0x(value: string) {
  return value.startsWith('0x') ? value.slice(2) : value;
}

function hex(bytes: Uint8Array | number[]) {
  return `0x${Buffer.from(bytes).toString('hex')}`;
}
