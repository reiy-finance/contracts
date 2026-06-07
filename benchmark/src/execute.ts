import type { SuiGrpcClient } from '@mysten/sui/grpc';
import type { Keypair } from '@mysten/sui/cryptography';
import type { Transaction } from '@mysten/sui/transactions';
import type { BenchEnv, TxRecord } from './types.ts';

export async function executeTx(
  client: SuiGrpcClient,
  keypair: Keypair,
  env: BenchEnv,
  tx: Transaction,
  op: string,
  index: number,
): Promise<{ record: TxRecord; result: any }> {
  tx.setSender(keypair.toSuiAddress());
  tx.setGasBudget(env.gasBudget);

  const start = performance.now();
  try {
    const bytes = await tx.build({ client });
    const { signature } = await keypair.signTransaction(bytes);
    let result = await (client as any).executeTransaction({
      transaction: bytes,
      signatures: [signature],
      include: {
        effects: true,
        events: true,
        balanceChanges: true,
        objectTypes: true,
      },
    });
    const digest = getDigest(result);
    if (digest && (client as any).waitForTransaction) {
      await (client as any).waitForTransaction({ digest }).catch(() => {});
    }
    if (digest && getEvents(result).length === 0 && (client as any).core?.getTransaction) {
      result = await (client as any).core.getTransaction({
        digest,
        include: {
          effects: true,
          events: true,
          objectTypes: true,
          balanceChanges: true,
        },
      });
    }
    return {
      result,
      record: {
        index,
        op,
        status: isSuccess(result) ? 'success' : 'failed',
        digest,
        latencyMs: performance.now() - start,
        ...gasFields(result),
        error: getError(result),
      },
    };
  } catch (error) {
    return {
      result: null,
      record: {
        index,
        op,
        status: 'failed',
        latencyMs: performance.now() - start,
        error: error instanceof Error ? error.message : String(error),
      },
    };
  }
}

export function getTx(result: any) {
  return result?.Transaction ?? result?.FailedTransaction ?? result?.transaction ?? result;
}

export function getDigest(result: any): string | undefined {
  const tx = getTx(result);
  return tx?.digest ?? result?.digest;
}

export function getEvents(result: any): any[] {
  const tx = getTx(result);
  return tx?.events ?? result?.events ?? [];
}

export function eventData(event: any): any {
  return event?.json ?? event?.contents?.json ?? event?.contents ?? event?.parsedJson ?? event?.data ?? event;
}

export function findEvent(result: any, suffix: string): any | null {
  return getEvents(result).find((event) => String(event?.type ?? event?.eventType ?? '').endsWith(suffix)) ?? null;
}

function isSuccess(result: any) {
  const tx = getTx(result);
  return Boolean(tx?.status?.success ?? tx?.effects?.status?.success ?? result?.effects?.status?.status === 'success');
}

function getError(result: any): string | undefined {
  const tx = getTx(result);
  const error = tx?.status?.error?.message ?? tx?.status?.error ?? tx?.effects?.status?.error?.message ?? tx?.effects?.status?.error;
  return error ? String(error) : undefined;
}

function gasFields(result: any) {
  const tx = getTx(result);
  const gas = tx?.effects?.gasUsed ?? result?.effects?.gasUsed ?? {};
  const computation = bigintish(gas.computationCost);
  const storage = bigintish(gas.storageCost);
  const rebate = bigintish(gas.storageRebate);
  const total = computation + storage - rebate;
  return {
    gasMist: total > 0n ? total.toString() : undefined,
    computationCost: gas.computationCost?.toString(),
    storageCost: gas.storageCost?.toString(),
    storageRebate: gas.storageRebate?.toString(),
  };
}

function bigintish(value: unknown) {
  if (value == null) return 0n;
  return BigInt(String(value));
}
