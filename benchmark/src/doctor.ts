import { createClient, getBalance, loadKeypair } from './client.ts';
import { loadBenchEnv, publicEnv } from './env.ts';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const env = loadBenchEnv();
const client = createClient(env);
const keypair = await loadKeypair();
const address = keypair.toSuiAddress();
const sui = await getBalance(client, address).catch((error) => ({ error: String(error) }));
const stake = env.stakeType ? await getBalance(client, address, env.stakeType).catch((error) => ({ error: String(error) })) : null;
const published = readPublished();
const objects = await checkObjects();

console.log(
  JSON.stringify(
    {
      address,
      env: publicEnv(env),
      published,
      checks: {
        envMatchesPublished: !published.publishedAt || sameId(env.packageId, published.publishedAt),
        objects,
      },
      balances: { sui, stake },
    },
    null,
    2,
  ),
);

function readPublished() {
  const path = resolve(import.meta.dir, '..', '..', 'Published.toml');
  if (!existsSync(path)) return { path, publishedAt: '' };
  const text = readFileSync(path, 'utf8');
  return {
    path,
    publishedAt: text.match(/published-at\s*=\s*"([^"]+)"/)?.[1] ?? '',
    originalId: text.match(/original-id\s*=\s*"([^"]+)"/)?.[1] ?? '',
    upgradeCapability: text.match(/upgrade-capability\s*=\s*"([^"]+)"/)?.[1] ?? '',
    toolchainVersion: text.match(/toolchain-version\s*=\s*"([^"]+)"/)?.[1] ?? '',
  };
}

async function checkObjects() {
  const entries = {
    package: env.packageId,
    auctionState: env.auctionStateId,
    globalConfig: env.globalConfigId,
    solverRegistry: env.solverRegistryId,
    feeVault: env.feeVaultId,
  };
  const out: Record<string, unknown> = {};
  for (const [name, objectId] of Object.entries(entries)) {
    if (!objectId) {
      out[name] = { ok: false, objectId: '' };
      continue;
    }
    try {
      const res = await client.core.getObject({ objectId });
      out[name] = {
        ok: Boolean((res as any).object),
        objectId,
        type: (res as any).object?.type ?? null,
      };
    } catch (error) {
      out[name] = { ok: false, objectId, error: error instanceof Error ? error.message : String(error) };
    }
  }
  return out;
}

function sameId(a: string, b: string) {
  return strip0x(a).padStart(64, '0').toLowerCase() === strip0x(b).padStart(64, '0').toLowerCase();
}

function strip0x(value: string) {
  return value.startsWith('0x') ? value.slice(2) : value;
}
