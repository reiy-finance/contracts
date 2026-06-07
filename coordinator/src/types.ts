export type CoordinatorConfig = {
  packageId: string;
  auctionStateId: string;
  globalConfigId: string;
  coordinatorKeyVersion: string;
  network: 'mainnet' | 'testnet' | 'devnet' | 'localnet';
  rpcUrl: string;
  storePath: string;
  port: number;
  indexerEnabled: boolean;
  indexerPollMs: number;
  indexerPageSize: number;
};

export type IntentSnapshot = {
  intentId: string;
  owner: string;
  sellType: string;
  buyType: string;
  sellAmount: string;
  minAmountOut: string;
  targetEpoch: string;
  deadline: string;
  status: 'open' | 'cancelled' | 'settled';
  updatedAt: string;
};

export type SolverQuote = {
  solver: string;
  intentIds: string[];
  fills: string[];
  grossPayouts: string[];
  protectedMins: string[];
  score: string;
  expiresAtMs: string;
  receivedAt: string;
};

export type SolutionPlan = {
  solutionId: string;
  solver: string;
  sellType: string;
  buyType: string;
  epoch: string;
  intentIds: string[];
  fills: string[];
  grossPayouts: string[];
  protectedMins: string[];
  expiresAtMs: string;
};

export type SolutionCertificate = SolutionPlan & {
  signatureHex: string;
  messageBcsHex: string;
};

export type EventCursor = {
  txDigest: string;
  eventSeq: string;
};

export type IndexerMeta = {
  cursor?: EventCursor;
  indexedEvents: number;
  lastSyncAt?: string;
  lastError?: string;
};

export type StoreShape = {
  intents: IntentSnapshot[];
  quotes: SolverQuote[];
  certificates: SolutionCertificate[];
  indexer: IndexerMeta;
};
