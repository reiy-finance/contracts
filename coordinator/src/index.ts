import { loadConfig, loadCoordinatorKeypair } from './config.ts';
import { publicKeyHex, signSolution } from './certificate.ts';
import { EventIndexer } from './indexer.ts';
import { JsonStore } from './store.ts';
import type { IntentSnapshot, SolutionPlan, SolverQuote } from './types.ts';

const config = loadConfig();
const keypair = loadCoordinatorKeypair();
const store = new JsonStore(config.storePath);
const indexer = new EventIndexer(config, store);

const server = Bun.serve({
  port: config.port,
  async fetch(req) {
    const url = new URL(req.url);
    try {
      if (req.method === 'GET' && url.pathname === '/health') {
        return json({
          ok: true,
          service: 'Execution Coordinator',
          packageId: config.packageId,
          keyVersion: config.coordinatorKeyVersion,
          publicKey: publicKeyHex(keypair),
          indexer: indexer.status(),
        });
      }

      if (req.method === 'GET' && url.pathname === '/indexer/status') {
        return json(indexer.status());
      }

      if (req.method === 'POST' && url.pathname === '/indexer/sync') {
        return json(await indexer.sync());
      }

      if (req.method === 'GET' && url.pathname === '/orderbook') {
        return json(
          store.orderbook({
            epoch: url.searchParams.get('epoch') ?? undefined,
            sellType: url.searchParams.get('sellType') ?? undefined,
            buyType: url.searchParams.get('buyType') ?? undefined,
          }),
        );
      }

      if (req.method === 'POST' && url.pathname === '/intents') {
        const body = (await req.json()) as IntentSnapshot;
        await store.upsertIntent({ ...body, updatedAt: new Date().toISOString() });
        return json({ ok: true });
      }

      if (req.method === 'POST' && url.pathname === '/quotes') {
        const body = (await req.json()) as Omit<SolverQuote, 'receivedAt'>;
        const quote: SolverQuote = { ...body, receivedAt: new Date().toISOString() };
        await store.addQuote(quote);
        return json({ ok: true, quote });
      }

      if (req.method === 'POST' && url.pathname === '/solutions/sign') {
        const plan = (await req.json()) as SolutionPlan;
        const certificate = await signSolution(config, keypair, plan);
        await store.addCertificate(certificate);
        return json(certificate);
      }

      if (req.method === 'GET' && url.pathname === '/certificates') {
        return json(store.all().certificates);
      }

      return json({ error: 'not found' }, 404);
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : String(error) }, 500);
    }
  },
});

console.log(`Execution Coordinator listening on http://127.0.0.1:${server.port}`);
indexer.start();

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
