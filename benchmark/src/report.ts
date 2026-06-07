import { existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import type { SettlementBatchSummary, Summary, TxRecord } from './types.ts';

export type RunFile<T extends TxRecord> = {
  runId: string;
  kind: string;
  startedAt: string;
  finishedAt: string;
  env: Record<string, unknown>;
  plans: unknown;
  records: T[];
  summary: Summary;
  summaries?: Record<string, Summary>;
  settlementBatchSummary?: SettlementBatchSummary;
};

export function createRunDir(baseDir: string, prefix: string) {
  mkdirSync(baseDir, { recursive: true });
  const runId = `${prefix}-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  const runDir = join(baseDir, runId);
  mkdirSync(runDir, { recursive: true });
  return { runId, runDir };
}

export async function writeJson(path: string, data: unknown) {
  await Bun.write(path, JSON.stringify(data, jsonReplacer, 2));
}

export async function writeRun<T extends TxRecord>(runDir: string, run: RunFile<T>) {
  await writeJson(join(runDir, 'records.json'), run.records);
  await writeJson(join(runDir, 'summary.json'), run.summary);
  if (run.settlementBatchSummary) await writeJson(join(runDir, 'settlement-batches.json'), run.settlementBatchSummary);
  await writeJson(join(runDir, 'run.json'), run);
  renderFigures(join(runDir, 'run.json'), join(runDir, 'figures'));
}

export function latestRun(baseDir: string, prefix: string) {
  if (!existsSync(baseDir)) throw new Error(`reports dir not found: ${baseDir}`);
  const dirs = readdirSync(baseDir).filter((name) => name.startsWith(`${prefix}-`)).sort();
  const latest = dirs.at(-1);
  if (!latest) throw new Error(`no ${prefix} run found in ${baseDir}`);
  return join(baseDir, latest, 'run.json');
}

export function readRun<T extends TxRecord>(path: string): RunFile<T> {
  return JSON.parse(readFileSync(path, 'utf8')) as RunFile<T>;
}

function renderFigures(runJson: string, outDir: string) {
  const script = join(import.meta.dir, '..', 'scripts', 'plot.py');
  if (!existsSync(script)) return;
  const result = spawnSync('python3', [script, runJson, '--out-dir', outDir], {
    cwd: join(import.meta.dir, '..'),
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    throw new Error(`figure rendering failed with exit code ${result.status}`);
  }
}

function jsonReplacer(_: string, value: unknown) {
  return typeof value === 'bigint' ? value.toString() : value;
}
