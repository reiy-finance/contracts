import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { SuiGrpcClient } from '@mysten/sui/grpc';
import type { Keypair } from '@mysten/sui/cryptography';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui/keypairs/secp256r1';
import type { BenchEnv } from './types.ts';

type KeypairCtor = typeof Ed25519Keypair | typeof Secp256k1Keypair | typeof Secp256r1Keypair;

export function createClient(env: BenchEnv) {
  return new SuiGrpcClient({
    network: env.network,
    baseUrl: env.rpcUrl,
  });
}

export async function loadKeypair(): Promise<Keypair> {
  const secret = process.env.BENCH_SECRET_KEY ?? process.env.SUI_SECRET_KEY ?? process.env.SUI_PRIVATE_KEY;
  if (secret) return keypairFromSecret(secret);

  const mnemonic = process.env.BENCH_MNEMONIC ?? process.env.SUI_MNEMONIC;
  if (mnemonic) return Ed25519Keypair.deriveKeypair(mnemonic);

  const fromKeystore = loadCliKeystoreKeypair();
  if (fromKeystore) return fromKeystore;

  throw new Error('Set SUI_SECRET_KEY, SUI_MNEMONIC, or configure a Sui CLI keystore');
}

export async function loadCoordinatorKeypair(): Promise<Ed25519Keypair> {
  const secret = process.env.COORDINATOR_SECRET_KEY ?? process.env.EXECUTION_COORDINATOR_SECRET_KEY;
  if (secret) return Ed25519Keypair.fromSecretKey(secret);

  const mnemonic = process.env.COORDINATOR_MNEMONIC ?? process.env.EXECUTION_COORDINATOR_MNEMONIC;
  if (mnemonic) return Ed25519Keypair.deriveKeypair(mnemonic);

  const keypair = await loadKeypair();
  if (keypair.getKeyScheme() !== 'ED25519') {
    throw new Error('Set COORDINATOR_SECRET_KEY for Ed25519 certificate signing');
  }
  return keypair as Ed25519Keypair;
}

export async function getBalance(client: SuiGrpcClient, owner: string, coinType?: string) {
  const anyClient = client as any;
  if (anyClient.core?.getBalance) {
    const res = await anyClient.core.getBalance({ owner, coinType });
    return res.balance ?? res;
  }
  if (anyClient.getBalance) {
    const res = await anyClient.getBalance({ owner, coinType });
    return res.balance ?? res;
  }
  return null;
}

function keypairFromSecret(secret: string): Keypair {
  for (const ctor of keypairCtors()) {
    try {
      return ctor.fromSecretKey(secret) as Keypair;
    } catch {}
  }

  const bytes = Buffer.from(secret, 'base64');
  if (bytes.length > 32) return keypairFromTaggedBytes(bytes);
  for (const ctor of keypairCtors()) {
    try {
      return ctor.fromSecretKey(bytes) as Keypair;
    } catch {}
  }
  throw new Error('Unsupported secret key format');
}

function loadCliKeystoreKeypair(): Keypair | null {
  const configDir = join(homedir(), '.sui', 'sui_config');
  const keystorePath = process.env.SUI_KEYSTORE ?? join(configDir, 'sui.keystore');
  if (!existsSync(keystorePath)) return null;

  const activeAddress = readActiveAddress(join(configDir, 'client.yaml'));
  const entries = JSON.parse(readFileSync(keystorePath, 'utf8')) as string[];
  const keypairs = entries.map((entry) => keypairFromTaggedBytes(Buffer.from(entry, 'base64')));
  if (!activeAddress) return keypairs[0] ?? null;
  return keypairs.find((keypair) => sameAddress(keypair.toSuiAddress(), activeAddress)) ?? null;
}

function keypairFromTaggedBytes(bytes: Uint8Array): Keypair {
  const tag = bytes[0];
  const key = bytes.slice(1);
  if (tag === 0) return Ed25519Keypair.fromSecretKey(key);
  if (tag === 1) return Secp256k1Keypair.fromSecretKey(key);
  if (tag === 2) return Secp256r1Keypair.fromSecretKey(key);
  throw new Error(`Unsupported Sui key scheme tag: ${tag}`);
}

function readActiveAddress(path: string) {
  if (!existsSync(path)) return '';
  const text = readFileSync(path, 'utf8');
  return text.match(/active_address:\s*"?([^"\s]+)"?/)?.[1] ?? '';
}

function sameAddress(a: string, b: string) {
  return strip0x(a).padStart(64, '0').toLowerCase() === strip0x(b).padStart(64, '0').toLowerCase();
}

function strip0x(value: string) {
  return value.startsWith('0x') ? value.slice(2) : value;
}

function keypairCtors(): KeypairCtor[] {
  return [Ed25519Keypair, Secp256k1Keypair, Secp256r1Keypair];
}
