import { createClient, loadKeypair } from './client.ts';
import { loadBenchEnv, requireReadyForBids } from './env.ts';
import { advancePhase } from './core.ts';

const env = loadBenchEnv();
requireReadyForBids(env);
const client = createClient(env);
const keypair = await loadKeypair();
const { record } = await advancePhase(client, keypair, env);

console.log(JSON.stringify(record, null, 2));
