import { createClient, loadKeypair } from './client.ts';
import { getBigInt, loadBenchEnv, requireReadyForSettlement } from './env.ts';
import { registerSolver } from './core.ts';

const env = loadBenchEnv();
requireReadyForSettlement(env);
const client = createClient(env);
const keypair = await loadKeypair();
const stake = getBigInt('STAKE_AMOUNT', 2_000_000_000n);
const url = process.env.SOLVER_URL ?? 'benchmark://local';
const { record } = await registerSolver(client, keypair, env, stake, url);

console.log(JSON.stringify(record, null, 2));
