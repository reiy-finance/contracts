import { createClient, loadKeypair } from './client.ts';
import { getInt, loadBenchEnv, requireReadyForReset } from './env.ts';
import { advancePhase, triggerFallback } from './core.ts';

const env = loadBenchEnv();
requireReadyForReset(env);
const client = createClient(env);
const keypair = await loadKeypair();
const waitMs = getInt('RESET_WAIT_MS', 11_000);

const fallback = await triggerFallback(client, keypair, env);
console.log(`[trigger_fallback] ${fallback.record.status} ${fallback.record.latencyMs.toFixed(0)}ms gas=${fallback.record.gasMist ?? '-'} ${fallback.record.error ?? ''}`);

if (fallback.record.status === 'success') {
  console.log(`wait ${waitMs}ms before opening next epoch`);
  await Bun.sleep(waitMs);
}

const advance = await advancePhase(client, keypair, env);
advance.record.op = 'advance_to_collection';
console.log(`[advance_to_collection] ${advance.record.status} ${advance.record.latencyMs.toFixed(0)}ms gas=${advance.record.gasMist ?? '-'} ${advance.record.error ?? ''}`);
