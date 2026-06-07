export type Network = 'local' | 'devnet' | 'testnet' | 'mainnet';

export type Direction = 'base_to_quote' | 'quote_to_base';

export type BenchEnv = {
  envFile: string;
  network: Network;
  rpcUrl: string;
  packageId: string;
  auctionStateId: string;
  globalConfigId: string;
  solverRegistryId: string;
  protocolTreasuryId: string;
  stakeType: string;
  baseType: string;
  quoteType: string;
  poolId: string;
  deepbookPackageId: string;
  deepbookRegistryId: string;
  clockId: string;
  gasBudget: bigint;
  reportsDir: string;
};

export type TxRecord = {
  index: number;
  op: string;
  status: 'success' | 'failed';
  digest?: string;
  latencyMs: number;
  gasMist?: string;
  computationCost?: string;
  storageCost?: string;
  storageRebate?: string;
  error?: string;
};

export type IntentPlan = {
  index: number;
  direction: Direction;
  baseType: string;
  quoteType: string;
  poolId: string;
  sellAmount: string;
  slippageBps: number;
  partialFillable: boolean;
  ttlMs: number;
  deadline: string;
};

export type IntentRecord = TxRecord & {
  intentId?: string;
  sellType?: string;
  buyType?: string;
  sellAmount: string;
  minAmountOut?: string;
  sbboFloor?: string;
  sbboMidPrice?: string;
  targetEpoch?: string;
  deadline: string;
};

export type BidPlan = {
  index: number;
  intentIds: string[];
  fills: string[];
  payouts: string[];
  declaredMulti: boolean;
  score: string;
};

export type BidRecord = TxRecord & {
  bidSeq?: string;
  intentCount: number;
  score: string;
  stakeReserved?: string;
};

export type SelectionRecord = TxRecord & {
  bidSeqs?: string[];
  totalScore?: string;
  bidCount?: number;
};

export type SolverStake = {
  stake: string;
  reserved: string;
  available: string;
};

export type Summary = {
  op: string;
  count: number;
  success: number;
  failed: number;
  wallMs: number;
  throughputPerSec: number;
  latencyMs: Stats;
  gasMist: Stats;
  errors: Record<string, number>;
};

export type BidBatchSummary = {
  op: string;
  batches: number;
  intents: number;
  batchSize: Stats;
  latencyPerIntentMs: Stats;
  gasPerIntentMist: Stats;
};

export type Stats = {
  min: number;
  max: number;
  avg: number;
  p50: number;
  p90: number;
  p99: number;
  sum: number;
};
