import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { getJsonRpcFullnodeUrl } from '@mysten/sui/jsonRpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import type { CoordinatorConfig } from './types.ts';

const networks = ['mainnet', 'testnet', 'devnet', 'localnet'] as const;
type Network = (typeof networks)[number];

export function loadConfig(): CoordinatorConfig {
  const storePath = resolve(process.env.COORDINATOR_STORE ?? 'data/store.json');
  const network = parseNetwork(process.env.SUI_NETWORK ?? process.env.SUI_ENV ?? 'testnet');
  mkdirSync(dirname(storePath), { recursive: true });
  return {
    packageId: required('REIY_PACKAGE_ID'),
    auctionStateId: required('AUCTION_STATE_ID'),
    globalConfigId: required('GLOBAL_CONFIG_ID'),
    coordinatorKeyVersion: process.env.COORDINATOR_KEY_VERSION ?? '1',
    network,
    rpcUrl: process.env.SUI_RPC_URL ?? getJsonRpcFullnodeUrl(network),
    storePath,
    port: Number(process.env.COORDINATOR_PORT ?? 8787),
    indexerEnabled: process.env.COORDINATOR_INDEXER !== '0',
    indexerPollMs: Number(process.env.COORDINATOR_INDEXER_POLL_MS ?? 5000),
    indexerPageSize: Number(process.env.COORDINATOR_INDEXER_PAGE_SIZE ?? 50),
  };
}

export function loadCoordinatorKeypair() {
  const secret = process.env.COORDINATOR_SECRET_KEY ?? process.env.EXECUTION_COORDINATOR_SECRET_KEY;
  if (secret) return Ed25519Keypair.fromSecretKey(secret);
  const mnemonic = process.env.COORDINATOR_MNEMONIC ?? process.env.EXECUTION_COORDINATOR_MNEMONIC;
  if (mnemonic) return Ed25519Keypair.deriveKeypair(mnemonic);
  throw new Error('Set COORDINATOR_SECRET_KEY or COORDINATOR_MNEMONIC');
}

function required(key: string) {
  const value = process.env[key];
  if (!value) throw new Error(`${key} is missing`);
  return value;
}

function parseNetwork(value: string): Network {
  if ((networks as readonly string[]).includes(value)) return value as Network;
  throw new Error(`Unsupported SUI_NETWORK: ${value}`);
}
