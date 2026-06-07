import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import type { BenchEnv, Direction, Network } from './types.ts';

const repoRoot = resolve(import.meta.dir, '../..');

export function loadBenchEnv(): BenchEnv {
  const envFile = resolve(process.env.ENV_FILE ?? process.env.BENCH_ENV_FILE ?? join(repoRoot, '.env.testnet'));
  const fileEnv = parseEnvFile(envFile);
  const get = (key: string, fallback = '') => process.env[key] ?? fileEnv[key] ?? fallback;
  const network = get('SUI_NETWORK', get('NETWORK', 'testnet')) as Network;
  const rpcUrl = get('SUI_RPC_URL', defaultRpcUrl(network));
  const packageId = required('REIY_PACKAGE_ID', get);
  const auctionStateId = required('AUCTION_STATE_ID', get);
  const globalConfigId = required('GLOBAL_CONFIG_ID', get);

  return {
    envFile,
    network,
    rpcUrl,
    packageId,
    auctionStateId,
    globalConfigId,
    solverRegistryId: get('SOLVER_REGISTRY_ID'),
    feeVaultId: get('FEE_VAULT_ID', get('USDC_FEE_VAULT_ID')),
    stakeType: get('STAKE_TYPE', get('SUI_TYPE', '0x2::sui::SUI')),
    baseType: get('BASE_TYPE', get('SUI_TYPE', '0x2::sui::SUI')),
    quoteType: get('QUOTE_TYPE', get('USDC_TYPE', get('DBUSDC_TYPE'))),
    poolId: get('POOL_ID', get('DEEPBOOK_SUI_DBUSDC_POOL', get('DEEPBOOK_SUI_USDC_POOL'))),
    deepbookPackageId: get('DEEPBOOK_PACKAGE_ID', get('DEEPBOOK_PKG')),
    deepbookRegistryId: get('DEEPBOOK_REGISTRY'),
    clockId: get('CLOCK_ID', '0x6'),
    coordinatorKeyVersion: get('COORDINATOR_KEY_VERSION', '1'),
    gasBudget: bigIntFromEnv('GAS_BUDGET', get('GAS_BUDGET', '500000000')),
    reportsDir: resolve(process.env.REPORTS_DIR ?? join(import.meta.dir, '..', 'reports')),
  };
}

export function getInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw || raw.trim() === '') return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value)) throw new Error(`${name} must be a number`);
  return value;
}

export function getSettlementChunkConfig(defaultSize = 4, defaultMax = 4) {
  const requested = getPositiveInt('SETTLEMENT_CHUNK_SIZE', defaultSize);
  const max = getPositiveInt('SETTLEMENT_MAX_CHUNK_SIZE', defaultMax);
  return {
    requested,
    max,
    effective: Math.min(requested, max),
    capped: requested > max,
  };
}

export function getBigInt(name: string, fallback: bigint): bigint {
  return bigIntFromEnv(name, process.env[name] ?? fallback.toString());
}

export function getBool(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  if (raw === '1' || raw === 'true') return true;
  if (raw === '0' || raw === 'false') return false;
  throw new Error(`${name} must be true/false or 1/0`);
}

export function getDirection(): Direction {
  const value = process.env.DIRECTION ?? 'base_to_quote';
  if (value !== 'base_to_quote' && value !== 'quote_to_base') {
    throw new Error('DIRECTION must be base_to_quote or quote_to_base');
  }
  return value;
}

export function requireReadyForSettlement(env: BenchEnv) {
  if (!env.solverRegistryId) throw new Error('SOLVER_REGISTRY_ID is missing');
  if (!env.feeVaultId) throw new Error('FEE_VAULT_ID is missing');
  if (!env.stakeType) throw new Error('STAKE_TYPE is missing');
}

export function publicEnv(env: BenchEnv) {
  return {
    network: env.network,
    rpcUrl: env.rpcUrl,
    packageId: env.packageId,
    auctionStateId: env.auctionStateId,
    globalConfigId: env.globalConfigId,
    solverRegistryId: env.solverRegistryId,
    feeVaultId: env.feeVaultId,
    stakeType: env.stakeType,
    baseType: env.baseType,
    quoteType: env.quoteType,
    poolId: env.poolId,
    coordinatorKeyVersion: env.coordinatorKeyVersion,
  };
}

function parseEnvFile(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  const env: Record<string, string> = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const idx = trimmed.indexOf('=');
    const key = trimmed.slice(0, idx).trim();
    let value = trimmed.slice(idx + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    env[key] = expand(value, env);
  }
  return env;
}

function expand(value: string, env: Record<string, string>) {
  return value.replace(/\$\{([^}]+)\}/g, (_, key) => process.env[key] ?? env[key] ?? '');
}

function required(key: string, get: (key: string, fallback?: string) => string) {
  const value = get(key);
  if (!value) throw new Error(`${key} is missing`);
  return value;
}

function getPositiveInt(name: string, fallback: number) {
  const value = getInt(name, fallback);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} must be a positive integer`);
  return value;
}

function bigIntFromEnv(name: string, value: string) {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${name} must be an integer`);
  }
}

function defaultRpcUrl(network: Network) {
  if (network === 'mainnet') return 'https://fullnode.mainnet.sui.io:443';
  if (network === 'devnet') return 'https://fullnode.devnet.sui.io:443';
  if (network === 'local') return 'http://127.0.0.1:9000';
  return 'https://fullnode.testnet.sui.io:443';
}
