// Copyright (c) Reiy Finance

/// Auction state machine: phases, Bid / PairBenchmark / Allocation registries, and winner selection.
module reiy::auction;

use deepbook::pool::Pool;
use reiy::config::GlobalConfig;
use reiy::events;
use reiy::intent_book::{Self, Intent};
use reiy::math;
use reiy::price_adapter;
use reiy::solver_registry::{Self, SolverRegistry, StakeReservationKey};
use reiy::types::{Self, PairKey};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// === Errors ===
#[error]
const EWrongPhase: vector<u8> = b"operation not allowed in current phase";
#[error]
const ESlippageTooHigh: vector<u8> = b"slippage tolerance exceeds configured max";
#[error]
const ENotInBatch: vector<u8> = b"intent not in current epoch batch";
#[error]
const EZeroFill: vector<u8> = b"fill amount must be > 0";
#[error]
const EFillExceedsSell: vector<u8> = b"fill exceeds intent sell amount";
#[error]
const EBelowMinimum: vector<u8> = b"payout below effective minimum";
#[error]
const EScopeMismatch: vector<u8> = b"declared scope does not match intent set";
#[error]
const EOverlappingBids: vector<u8> = b"intents overlap within bid/allocation";
#[error]
const EStakeTooSmall: vector<u8> = b"available stake below required amount";
#[error]
const ELengthMismatch: vector<u8> = b"input vectors length mismatch";
#[error]
const EEmptyIntents: vector<u8> = b"bid/benchmark/allocation has no intents";
#[error]
const EMultiBidInBenchmark: vector<u8> = b"multi-pair bid cannot appear in a benchmark";
#[error]
const EBenchmarkPairMismatch: vector<u8> = b"benchmark bid not for declared pair";
#[error]
const ENoBenchmarkForPair: vector<u8> = b"no benchmark submitted for a touched pair";
#[error]
const EBelowFloor: vector<u8> = b"allocation payout below floor";
#[error]
const EScoreSumMismatch: vector<u8> = b"declared total_score != sum of bid scores";
#[error]
const EBidEpsrInconsistent: vector<u8> = b"bid payouts violate uniform ratio within a pair";
#[error]
const ESolverNotActive: vector<u8> = b"solver not registered/active";
#[error]
const EUseFallbackAfterDeadline: vector<u8> = b"settlement deadline passed; use fallback";
#[error]
const EBatchLimitExceeded: vector<u8> = b"batch size limit exceeded";

// === Phase ===
public enum AuctionPhase has copy, drop, store {
    IntentCollection,
    Bid,
    AllocationSelection,
    Settlement,
    Close,
    Aborted,
    Failed,
}

/// Lightweight snapshot of an intent's fields recorded at submission time.
/// Allows bid/allocation validation without loading the full typed Intent object.
/// * `pair`            - Directed pair of the intent
/// * `min_amount_out`  - User minimum acceptable buy amount
/// * `sell_amount`     - Total sell amount locked in the intent
/// * `partial_fillable`- Whether partial fills are allowed
public struct IntentMeta has copy, drop, store {
    pair: PairKey,
    min_amount_out: u64,
    sell_amount: u64,
    partial_fillable: bool,
    deadline: u64,
}

/// An executable settlement plan submitted by a solver during the Bid phase.
/// * `solver`      - Address of the solver that submitted this bid
/// * `intents`     - IDs of intents covered by this bid
/// * `fills`       - Fill amounts parallel to `intents`
/// * `payouts`     - Proposed net payouts parallel to `intents`
/// * `m_effs`      - Effective minimums parallel to `intents` (ceil proportional)
/// * `pairs`       - Directed pair of each covered intent parallel to `intents`
/// * `is_multi`    - True when intents span more than one directed pair
/// * `score`       - Normalized surplus score committed by the solver
/// * `stake_reserved` - Amount of solver stake reserved by this bid
public struct Bid has drop, store {
    solver: address,
    intents: vector<ID>,
    fills: vector<u64>,
    payouts: vector<u64>,
    m_effs: vector<u64>,
    pairs: vector<PairKey>,
    is_multi: bool,
    score: u64,
    stake_reserved: u64,
}

/// The best submitted PairBenchmark for a directed pair (argmax by total_score).
/// * `auctioneer`   - Address that submitted this benchmark
/// * `total_score`  - Sum of constituent bid scores; used to elect the best benchmark per pair
/// * `intents`      - Intent IDs covered by this benchmark
/// * `payouts`      - Per-intent benchmark payouts `bm_i` parallel to `intents`
public struct BenchmarkEntry has drop, store {
    seq: u64,
    auctioneer: address,
    total_score: u64,
    intents: vector<ID>,
    payouts: vector<u64>,
    stake_reserved: u64,
}

/// A proposed set of Bids competing to be the winning allocation.
/// * `auctioneer`  - Address that submitted this allocation
/// * `bid_seqs`    - Indices into `AuctionState.bids` for the constituent bids
/// * `total_score` - Declared sum of constituent bid scores; verified on-chain
/// * `stake_reserved` - Auctioneer stake reserved on this allocation
public struct Allocation has drop, store {
    auctioneer: address,
    bid_seqs: vector<u64>,
    total_score: u64,
    stake_reserved: u64,
}

/// EPSR reference ratio anchored to the first settled intent of a directed pair.
/// Subsequent intents in the same pair must match this ratio exactly.
/// * `floor_ref`  - Benchmark floor of the reference intent
/// * `payout_ref` - Net payout of the reference intent
public struct RatioRef has copy, drop, store {
    floor_ref: u64,
    payout_ref: u64,
}

/// Shared auction state machine. All per-epoch transient state is reset at epoch rollover.
/// * `id`                        - UID of the shared object
/// * `current_epoch`             - Monotonically increasing epoch counter
/// * `phase`                     - Current lifecycle phase
/// * `phase_end_ms`              - Timestamp when the current phase window closes (ms)
/// * `settlement_deadline_ms`    - Absolute deadline for the winning solver to settle (ms)
/// * `next_epoch_open_after_ms`  - Earliest time a new epoch may start after close/abort (ms)
/// * `batch`                     - IDs of all intents eligible for settlement in this epoch
/// * `intent_meta`               - Lightweight metadata snapshot per batch intent
/// * `requeued`                  - Partially-filled intent IDs queued for the next epoch
/// * `requeue_meta`              - Updated metadata for requeued intents
/// * `bids`                      - All bids submitted this epoch (indexed by sequence number)
/// * `pair_benchmarks`           - Best PairBenchmark per directed pair (argmax by score)
/// * `allocations`               - All allocation candidates submitted this epoch
/// * `winner_selected`           - Whether a winner has been committed for this epoch
/// * `winner_is_fallback`        - Whether the winner was selected via the benchmark fallback path
/// * `winner_intents`            - IDs of intents assigned to the winning allocation
/// * `winner_solver_of`          - Maps each winning intent ID to the responsible solver address
/// * `intent_floor`              - Committed floor `max(m_eff, bm_i)` per winning intent
/// * `committed_total_score`     - Normalized score committed by the winning allocation
/// * `committed_k_by_pair`       - Committed uniform improvement ratio per directed pair
/// * `current_epoch_score_surplus` - Accumulated verified normalized surplus so far this epoch
/// * `settled_intent_count`      - Number of winning intents fully settled this epoch
/// * `settled_score_value_sum`   - Accumulated normalized floor value of settled intents (for fee calc)
/// * `pair_ratio_refs`           - EPSR reference ratio per directed pair set by first settled intent
/// * `intent_settled`            - IDs of intents already settled; prevents double-consume
/// * `solver_actual_score`       - Verified score contribution per solver; used for reward split
/// * `winner_reservation_of`     - Maps each winning intent to its bid/benchmark reservation
/// * `winning_reservations`      - Reservations retained for settlement close/fallback
public struct AuctionState has key {
    id: UID,
    current_epoch: u64,
    phase: AuctionPhase,
    phase_end_ms: u64,
    settlement_deadline_ms: u64,
    next_epoch_open_after_ms: u64,
    batch: VecSet<ID>,
    intent_meta: VecMap<ID, IntentMeta>,
    requeued: VecSet<ID>,
    requeue_meta: VecMap<ID, IntentMeta>,
    bids: vector<Bid>,
    pair_benchmarks: VecMap<PairKey, BenchmarkEntry>,
    next_benchmark_seq: u64,
    allocations: vector<Allocation>,
    winner_selected: bool,
    winner_is_fallback: bool,
    winner_intents: VecSet<ID>,
    winner_solver_of: VecMap<ID, address>,
    intent_floor: VecMap<ID, u64>,
    committed_total_score: u64,
    committed_k_by_pair: VecMap<PairKey, u64>,
    current_epoch_score_surplus: u64,
    settled_intent_count: u64,
    settled_score_value_sum: u64,
    pair_ratio_refs: VecMap<PairKey, RatioRef>,
    intent_settled: VecSet<ID>,
    solver_actual_score: VecMap<address, u64>,
    winner_reservation_of: VecMap<ID, StakeReservationKey>,
    winning_reservations: VecSet<StakeReservationKey>,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(new_state(ctx));
}

fun new_state(ctx: &mut TxContext): AuctionState {
    AuctionState {
        id: object::new(ctx),
        current_epoch: 0,
        phase: AuctionPhase::IntentCollection,
        phase_end_ms: 0,
        settlement_deadline_ms: 0,
        next_epoch_open_after_ms: 0,
        batch: vec_set::empty(),
        intent_meta: vec_map::empty(),
        requeued: vec_set::empty(),
        requeue_meta: vec_map::empty(),
        bids: vector[],
        pair_benchmarks: vec_map::empty(),
        next_benchmark_seq: 0,
        allocations: vector[],
        winner_selected: false,
        winner_is_fallback: false,
        winner_intents: vec_set::empty(),
        winner_solver_of: vec_map::empty(),
        intent_floor: vec_map::empty(),
        committed_total_score: 0,
        committed_k_by_pair: vec_map::empty(),
        current_epoch_score_surplus: 0,
        settled_intent_count: 0,
        settled_score_value_sum: 0,
        pair_ratio_refs: vec_map::empty(),
        intent_settled: vec_set::empty(),
        solver_actual_score: vec_map::empty(),
        winner_reservation_of: vec_map::empty(),
        winning_reservations: vec_set::empty(),
    }
}

fun phase_tag(p: &AuctionPhase): u8 {
    match (p) {
        AuctionPhase::IntentCollection => 0,
        AuctionPhase::Bid => 1,
        AuctionPhase::AllocationSelection => 2,
        AuctionPhase::Settlement => 3,
        AuctionPhase::Close => 4,
        AuctionPhase::Aborted => 5,
        AuctionPhase::Failed => 6,
    }
}

fun is_collection(s: &AuctionState): bool { phase_tag(&s.phase) == 0 }

fun is_terminal(s: &AuctionState): bool {
    let t = phase_tag(&s.phase);
    t == 4 || t == 5 || t == 6
}

public fun current_epoch(s: &AuctionState): u64 { s.current_epoch }

public fun phase_code(s: &AuctionState): u8 { phase_tag(&s.phase) }

public fun is_settlement(s: &AuctionState): bool { phase_tag(&s.phase) == 3 }

// === Intent submission ===

/// Submit an intent selling the pool's BASE token to buy its QUOTE token.
public fun submit_intent_sell_base<Base, Quote>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    pool: &Pool<Base, Quote>,
    coin: Coin<Base>,
    min_amount_out: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let mid = price_adapter::read_mid_price(pool, config, clock);
    let floor = price_adapter::sbbo_floor_base_to_quote(coin.value(), mid, slippage_tolerance_bps);
    submit_intent_inner<Base, Quote>(
        state,
        config,
        coin,
        min_amount_out,
        floor,
        mid,
        slippage_tolerance_bps,
        partial_fillable,
        deadline,
        clock,
        ctx,
    )
}

/// Submit an intent selling the pool's QUOTE token to buy its BASE token.
public fun submit_intent_sell_quote<Base, Quote>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    pool: &Pool<Base, Quote>,
    coin: Coin<Quote>,
    min_amount_out: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let mid = price_adapter::read_mid_price(pool, config, clock);
    let floor = price_adapter::sbbo_floor_quote_to_base(coin.value(), mid, slippage_tolerance_bps);
    submit_intent_inner<Quote, Base>(
        state,
        config,
        coin,
        min_amount_out,
        floor,
        mid,
        slippage_tolerance_bps,
        partial_fillable,
        deadline,
        clock,
        ctx,
    )
}

fun submit_intent_inner<Sell, Buy>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    coin: Coin<Sell>,
    min_amount_out: u64,
    sbbo_floor: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(is_collection(state), EWrongPhase);
    assert!(slippage_tolerance_bps <= config.max_slippage_tolerance_bps(), ESlippageTooHigh);
    let pair = types::pair_key<Sell, Buy>();
    config.assert_pair_supported(&pair);

    let sell_amount = coin.value();
    let id = intent_book::create_intent<Sell, Buy>(
        coin,
        min_amount_out,
        sbbo_floor,
        sbbo_mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        state.current_epoch,
        deadline,
        clock,
        ctx,
    );
    record_intent_meta(state, id, pair, min_amount_out, sell_amount, partial_fillable, deadline);
    id
}

fun record_intent_meta(
    state: &mut AuctionState,
    id: ID,
    pair: PairKey,
    min_amount_out: u64,
    sell_amount: u64,
    partial_fillable: bool,
    deadline: u64,
) {
    state.batch.insert(id);
    state
        .intent_meta
        .insert(id, IntentMeta { pair, min_amount_out, sell_amount, partial_fillable, deadline });
}

// === Intent cancel / update ===

public fun cancel_intent<Sell, Buy>(
    state: &mut AuctionState,
    intent: Intent<Sell, Buy>,
    ctx: &mut TxContext,
) {
    let id = intent.intent_id();
    assert!(can_modify_intent(state, &id), EWrongPhase);
    if (state.batch.contains(&id)) { state.batch.remove(&id); state.intent_meta.remove(&id); };
    intent_book::cancel_intent(intent, ctx);
}

fun can_modify_intent(state: &AuctionState, id: &ID): bool {
    if (is_terminal(state)) return true;
    if (!state.winner_selected) return true;
    !state.winner_intents.contains(id)
}

// === Phase advancement ===

public fun advance_phase<Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    clock: &Clock,
) {
    config.assert_solver_registry_id(solver_registry::id(registry));
    let now = clock.timestamp_ms();
    let t = phase_tag(&state.phase);
    if (t == 0) {
        if (now >= state.phase_end_ms) {
            state.phase = AuctionPhase::Bid;
            state.phase_end_ms = now + config.bid_duration_ms();
            emit_phase(state, now);
        }
    } else if (t == 1) {
        if (now >= state.phase_end_ms) {
            state.phase = AuctionPhase::AllocationSelection;
            state.phase_end_ms = now + config.selection_duration_ms();
            emit_phase(state, now);
        }
    } else if (t == 2) {
        if (now >= state.phase_end_ms) {
            run_selection(state, registry, config, now);
        }
    } else if (t == 3) {
        if (now > state.settlement_deadline_ms) {
            assert!(false, EUseFallbackAfterDeadline);
        }
    } else {
        if (now >= state.next_epoch_open_after_ms) {
            start_new_epoch(state, config, now);
        }
    }
}

fun emit_phase(state: &AuctionState, now: u64) {
    events::emit_epoch_advanced(state.current_epoch, phase_tag(&state.phase), now);
}

fun start_new_epoch(state: &mut AuctionState, config: &GlobalConfig, now: u64) {
    state.current_epoch = state.current_epoch + 1;
    state.phase = AuctionPhase::IntentCollection;
    state.phase_end_ms = now + config.collection_duration_ms();
    state.settlement_deadline_ms = 0;
    state.next_epoch_open_after_ms = 0;
    state.bids = vector[];
    state.pair_benchmarks = vec_map::empty();
    state.next_benchmark_seq = 0;
    state.allocations = vector[];
    state.winner_selected = false;
    state.winner_is_fallback = false;
    state.winner_intents = vec_set::empty();
    state.winner_solver_of = vec_map::empty();
    state.intent_floor = vec_map::empty();
    state.committed_total_score = 0;
    state.committed_k_by_pair = vec_map::empty();
    state.current_epoch_score_surplus = 0;
    state.settled_intent_count = 0;
    state.settled_score_value_sum = 0;
    state.pair_ratio_refs = vec_map::empty();
    state.intent_settled = vec_set::empty();
    state.solver_actual_score = vec_map::empty();
    state.winner_reservation_of = vec_map::empty();
    state.winning_reservations = vec_set::empty();
    state.batch = vec_set::empty();
    state.intent_meta = vec_map::empty();
    let reqs = state.requeued.into_keys();
    let mut i = 0;
    let n = reqs.length();
    while (i < n) {
        let id = reqs[i];
        let meta = *state.requeue_meta.get(&id);
        state.batch.insert(id);
        state.intent_meta.insert(id, meta);
        i = i + 1;
    };
    state.requeued = vec_set::empty();
    state.requeue_meta = vec_map::empty();
    emit_phase(state, now);
}

// === Bid submission ===

public fun submit_bid<Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    intent_ids: vector<ID>,
    fills: vector<u64>,
    payouts: vector<u64>,
    declared_multi: bool,
    score: u64,
    ctx: &TxContext,
) {
    assert!(phase_tag(&state.phase) == 1, EWrongPhase);
    config.assert_solver_registry_id(solver_registry::id(registry));
    let solver = ctx.sender();
    assert!(solver_registry::is_active(registry, config, solver), ESolverNotActive);

    let n = intent_ids.length();
    assert!(n > 0, EEmptyIntents);
    assert!(n <= config.max_allocation_intents(), EBatchLimitExceeded);
    assert!(fills.length() == n && payouts.length() == n, ELengthMismatch);

    let mut m_effs = vector[];
    let mut pairs = vector[];
    let mut seen = vec_set::empty<ID>();
    let mut i = 0;
    while (i < n) {
        let id = intent_ids[i];
        assert!(state.batch.contains(&id), ENotInBatch);
        assert!(!seen.contains(&id), EOverlappingBids);
        seen.insert(id);
        let meta = state.intent_meta.get(&id);
        let fill = fills[i];
        assert!(fill > 0, EZeroFill);
        assert!(fill <= meta.sell_amount, EFillExceedsSell);
        let m_eff = math::mul_div_ceil(meta.min_amount_out, fill, meta.sell_amount);
        assert!(payouts[i] >= m_eff, EBelowMinimum);
        m_effs.push_back(m_eff);
        pairs.push_back(meta.pair);
        i = i + 1;
    };

    let is_multi = distinct_pair_count(&pairs) > 1;
    assert!(is_multi == declared_multi, EScopeMismatch);
    assert_bid_epsr_consistent(&pairs, &payouts, &m_effs);

    let required = required_bid_stake(config, score);
    assert!(solver_registry::available_stake_of(registry, solver) >= required, EStakeTooSmall);

    let seq = state.bids.length();
    solver_registry::reserve_stake(
        registry,
        config,
        solver,
        solver_registry::bid_reservation_key(state.current_epoch, seq),
        required,
    );
    let bid = Bid {
        solver,
        intents: intent_ids,
        fills,
        payouts,
        m_effs,
        pairs,
        is_multi,
        score,
        stake_reserved: required,
    };
    state.bids.push_back(bid);
    events::emit_bid_submitted(seq, solver, state.current_epoch, is_multi, score, required, n);
}

fun required_bid_stake(config: &GlobalConfig, score: u64): u64 {
    let scaled = math::mul_div_floor(score, config.grief_factor_bps(), math::bps_denom());
    let min = config.min_solver_stake();
    if (scaled > min) { scaled } else { min }
}

fun distinct_pair_count(pairs: &vector<PairKey>): u64 {
    let mut seen = vec_set::empty<PairKey>();
    let mut i = 0;
    let n = pairs.length();
    while (i < n) {
        if (!seen.contains(&pairs[i])) seen.insert(pairs[i]);
        i = i + 1;
    };
    seen.length()
}

/// Within each directed pair covered by the bid, all (payout, m_eff) must share the same
/// exact proportional ratio (the bid is internally EPSR-consistent).
fun assert_bid_epsr_consistent(
    pairs: &vector<PairKey>,
    payouts: &vector<u64>,
    m_effs: &vector<u64>,
) {
    let n = pairs.length();
    let mut refs = vec_map::empty<PairKey, RatioRef>();
    let mut i = 0;
    while (i < n) {
        let p = pairs[i];
        if (refs.contains(&p)) {
            let r = refs.get(&p);
            assert!(
                math::cross_ratio_equal(
                    payouts[i],
                    m_effs[i],
                    r.payout_ref,
                    r.floor_ref,
                ),
                EBidEpsrInconsistent,
            );
        } else {
            refs.insert(p, RatioRef { floor_ref: m_effs[i], payout_ref: payouts[i] });
        };
        i = i + 1;
    };
}

// === PairBenchmark submission ===

public fun submit_pair_benchmark<Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    bid_seqs: vector<u64>,
    ctx: &TxContext,
) {
    assert!(phase_tag(&state.phase) == 2, EWrongPhase);
    config.assert_solver_registry_id(solver_registry::id(registry));
    let m = bid_seqs.length();
    assert!(m > 0, EEmptyIntents);
    assert!(m <= config.max_allocation_bids(), EBatchLimitExceeded);
    let auctioneer = ctx.sender();
    assert!(solver_registry::is_active(registry, config, auctioneer), ESolverNotActive);

    let mut pair_opt: Option<PairKey> = option::none();
    let mut intents = vector[];
    let mut payouts = vector[];
    let mut total_score = 0u64;
    let mut seen = vec_set::empty<ID>();

    let mut i = 0;
    while (i < m) {
        let bid = &state.bids[bid_seqs[i]];
        assert!(!bid.is_multi, EMultiBidInBenchmark);
        // single-pair bid: pair is pairs[0]
        let bp = bid.pairs[0];
        if (pair_opt.is_some()) {
            assert!(*pair_opt.borrow() == bp, EBenchmarkPairMismatch);
        } else {
            pair_opt = option::some(bp);
        };
        total_score = total_score + bid.score;
        let mut j = 0;
        let bn = bid.intents.length();
        while (j < bn) {
            let id = bid.intents[j];
            assert!(!seen.contains(&id), EOverlappingBids);
            seen.insert(id);
            intents.push_back(id);
            payouts.push_back(bid.payouts[j]);
            j = j + 1;
        };
        assert!(intents.length() <= config.max_allocation_intents(), EBatchLimitExceeded);
        i = i + 1;
    };

    let pair = *pair_opt.borrow();
    let required = config.required_benchmark_stake();
    let bid_count = m;
    let mut accepted = false;
    if (state.pair_benchmarks.contains(&pair)) {
        let existing = state.pair_benchmarks.get(&pair);
        if (total_score > existing.total_score) {
            let old_key = solver_registry::benchmark_reservation_key(state.current_epoch, existing.seq);
            solver_registry::release_stake(registry, old_key);
            let (_, _) = state.pair_benchmarks.remove(&pair);
            let seq = state.next_benchmark_seq;
            state.next_benchmark_seq = seq + 1;
            solver_registry::reserve_stake(
                registry,
                config,
                auctioneer,
                solver_registry::benchmark_reservation_key(state.current_epoch, seq),
                required,
            );
            let entry = BenchmarkEntry {
                seq,
                auctioneer,
                total_score,
                intents,
                payouts,
                stake_reserved: required,
            };
            state.pair_benchmarks.insert(pair, entry);
            accepted = true;
        };
    } else {
        assert!(state.pair_benchmarks.length() < config.max_allocation_pairs(), EBatchLimitExceeded);
        let seq = state.next_benchmark_seq;
        state.next_benchmark_seq = seq + 1;
        solver_registry::reserve_stake(
            registry,
            config,
            auctioneer,
            solver_registry::benchmark_reservation_key(state.current_epoch, seq),
            required,
        );
        let entry = BenchmarkEntry {
            seq,
            auctioneer,
            total_score,
            intents,
            payouts,
            stake_reserved: required,
        };
        state.pair_benchmarks.insert(pair, entry);
        accepted = true;
    };
    events::emit_pair_benchmark_submitted(
        auctioneer,
        state.current_epoch,
        pair,
        total_score,
        if (accepted) required else 0,
        bid_count,
    );
}

// === Allocation submission ===

public fun submit_allocation<Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    bid_seqs: vector<u64>,
    total_score: u64,
    ctx: &TxContext,
) {
    assert!(phase_tag(&state.phase) == 2, EWrongPhase);
    config.assert_solver_registry_id(solver_registry::id(registry));
    assert!(bid_seqs.length() > 0, EEmptyIntents);
    assert!(bid_seqs.length() <= config.max_allocation_bids(), EBatchLimitExceeded);
    let auctioneer = ctx.sender();
    assert!(solver_registry::is_active(registry, config, auctioneer), ESolverNotActive);

    validate_allocation(state, config, &bid_seqs, total_score);

    let idx = state.allocations.length();
    let bid_count = bid_seqs.length();
    let required = config.required_allocation_stake();
    solver_registry::reserve_stake(
        registry,
        config,
        auctioneer,
        solver_registry::allocation_reservation_key(state.current_epoch, idx),
        required,
    );
    state
        .allocations
        .push_back(Allocation {
            auctioneer,
            bid_seqs,
            total_score,
            stake_reserved: required,
        });
    events::emit_allocation_submitted(
        idx,
        auctioneer,
        state.current_epoch,
        total_score,
        required,
        bid_count,
    );
}

fun validate_allocation(
    state: &AuctionState,
    config: &GlobalConfig,
    bid_seqs: &vector<u64>,
    declared_score: u64,
) {
    let mut seen = vec_set::empty<ID>();
    let mut seen_pairs = vec_set::empty<PairKey>();
    let mut score_sum = 0u64;
    let mut i = 0;
    let m = bid_seqs.length();
    while (i < m) {
        let bid = &state.bids[bid_seqs[i]];
        score_sum = score_sum + bid.score;
        let mut j = 0;
        let bn = bid.intents.length();
        while (j < bn) {
            let id = bid.intents[j];
            assert!(!seen.contains(&id), EOverlappingBids);
            seen.insert(id);
            if (!seen_pairs.contains(&bid.pairs[j])) seen_pairs.insert(bid.pairs[j]);
            let bm = benchmark_payout(state, &bid.pairs[j], &id);
            let floor = max_u64(bid.m_effs[j], bm);
            assert!(bid.payouts[j] >= floor, EBelowFloor);
            // touched pair must have a benchmark
            assert!(state.pair_benchmarks.contains(&bid.pairs[j]), ENoBenchmarkForPair);
            j = j + 1;
        };
        i = i + 1;
    };
    assert!(seen.length() <= config.max_allocation_intents(), EBatchLimitExceeded);
    assert!(seen_pairs.length() <= config.max_allocation_pairs(), EBatchLimitExceeded);
    assert!(score_sum == declared_score, EScoreSumMismatch);
}

fun benchmark_payout(state: &AuctionState, pair: &PairKey, id: &ID): u64 {
    if (!state.pair_benchmarks.contains(pair)) return 0;
    let entry = state.pair_benchmarks.get(pair);
    let (found, idx) = entry.intents.index_of(id);
    if (found) { entry.payouts[idx] } else { 0 }
}

fun max_u64(a: u64, b: u64): u64 { if (a >= b) a else b }

// === Winner selection ===

fun run_selection<Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    now: u64,
) {
    let mut best_idx: Option<u64> = option::none();
    let mut best_score = 0u64;
    let mut i = 0;
    let n = state.allocations.length();
    while (i < n) {
        let alloc = &state.allocations[i];
        if (allocation_is_valid(state, &alloc.bid_seqs, alloc.total_score)) {
            if (best_idx.is_none() || alloc.total_score > best_score) {
                best_idx = option::some(i);
                best_score = alloc.total_score;
            };
        };
        i = i + 1;
    };

    if (best_idx.is_some()) {
        let idx = *best_idx.borrow();
        let winning_bid_seqs = state.allocations[idx].bid_seqs;
        commit_winner_from_allocation(state, idx, config);
        release_bid_reservations_except(state, registry, &winning_bid_seqs);
        release_all_allocation_reservations(state, registry);
        release_all_benchmark_reservations(state, registry);
        state.winner_is_fallback = false;
    } else if (state.pair_benchmarks.length() > 0) {
        commit_winner_from_benchmarks(state, config);
        release_all_bid_reservations(state, registry);
        release_all_allocation_reservations(state, registry);
        state.winner_is_fallback = true;
    } else {
        release_all_open_reservations(state, registry);
        state.phase = AuctionPhase::Aborted;
        state.next_epoch_open_after_ms = now + config.min_batch_collect_ms();
        emit_phase(state, now);
        return
    };

    state.winner_selected = true;
    state.phase = AuctionPhase::Settlement;
    state.settlement_deadline_ms = now + config.settlement_deadline_ms();
    events::emit_winner_selected(
        state.current_epoch,
        state.committed_total_score,
        state.winner_intents.length(),
        state.winner_is_fallback,
    );
    emit_phase(state, now);
}

fun allocation_is_valid(state: &AuctionState, bid_seqs: &vector<u64>, declared_score: u64): bool {
    let mut seen = vec_set::empty<ID>();
    let mut score_sum = 0u64;
    let mut i = 0;
    let m = bid_seqs.length();
    while (i < m) {
        let bid = &state.bids[bid_seqs[i]];
        score_sum = score_sum + bid.score;
        let mut j = 0;
        let bn = bid.intents.length();
        while (j < bn) {
            let id = bid.intents[j];
            if (seen.contains(&id)) return false;
            seen.insert(id);
            if (!state.pair_benchmarks.contains(&bid.pairs[j])) return false;
            let bm = benchmark_payout(state, &bid.pairs[j], &id);
            let floor = max_u64(bid.m_effs[j], bm);
            if (bid.payouts[j] < floor) return false;
            j = j + 1;
        };
        i = i + 1;
    };
    score_sum == declared_score
}

fun commit_winner_from_allocation(
    state: &mut AuctionState,
    alloc_idx: u64,
    _config: &GlobalConfig,
) {
    let bid_seqs = state.allocations[alloc_idx].bid_seqs;
    state.committed_total_score = state.allocations[alloc_idx].total_score;
    let mut i = 0;
    let m = bid_seqs.length();
    while (i < m) {
        let seq = bid_seqs[i];
        let solver = state.bids[seq].solver;
        let intents = state.bids[seq].intents;
        let payouts = state.bids[seq].payouts;
        let m_effs = state.bids[seq].m_effs;
        let pairs = state.bids[seq].pairs;
        let reservation_key = solver_registry::bid_reservation_key(state.current_epoch, seq);
        commit_bid_intents(state, solver, reservation_key, &intents, &payouts, &m_effs, &pairs);
        i = i + 1;
    };
}

fun commit_winner_from_benchmarks(state: &mut AuctionState, _config: &GlobalConfig) {
    let pairs = state.pair_benchmarks.keys();
    let mut total = 0u64;
    let mut i = 0;
    let n = pairs.length();
    while (i < n) {
        let pair = pairs[i];
        let entry = state.pair_benchmarks.get(&pair);
        let auctioneer = entry.auctioneer;
        let reservation_key = solver_registry::benchmark_reservation_key(state.current_epoch, entry.seq);
        let intents = entry.intents;
        let payouts = entry.payouts;
        total = total + entry.total_score;
        let mut m_effs = vector[];
        let mut pks = vector[];
        let mut j = 0;
        let bn = intents.length();
        while (j < bn) {
            let id = intents[j];
            let meta = state.intent_meta.get(&id);
            m_effs.push_back(meta.min_amount_out);
            pks.push_back(meta.pair);
            j = j + 1;
        };
        commit_bid_intents(state, auctioneer, reservation_key, &intents, &payouts, &m_effs, &pks);
        i = i + 1;
    };
    state.committed_total_score = total;
}

fun commit_bid_intents(
    state: &mut AuctionState,
    solver: address,
    reservation_key: StakeReservationKey,
    intents: &vector<ID>,
    payouts: &vector<u64>,
    m_effs: &vector<u64>,
    pairs: &vector<PairKey>,
) {
    let n = intents.length();
    let mut i = 0;
    while (i < n) {
        let id = intents[i];
        let bm = benchmark_payout(state, &pairs[i], &id);
        let floor = max_u64(m_effs[i], bm);
        state.winner_intents.insert(id);
        state.winner_solver_of.insert(id, solver);
        state.winner_reservation_of.insert(id, reservation_key);
        state.intent_floor.insert(id, floor);
        if (!state.winning_reservations.contains(&reservation_key)) {
            state.winning_reservations.insert(reservation_key);
        };
        if (!state.committed_k_by_pair.contains(&pairs[i])) {
            state.committed_k_by_pair.insert(pairs[i], math::fixed_ratio(payouts[i], floor));
        };
        i = i + 1;
    };
}

fun release_bid_reservations_except<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
    keep: &vector<u64>,
) {
    let mut i = 0;
    let n = state.bids.length();
    while (i < n) {
        if (!keep.contains(&i)) {
            solver_registry::release_stake(
                registry,
                solver_registry::bid_reservation_key(state.current_epoch, i),
            );
        };
        i = i + 1;
    };
}

fun release_all_bid_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
) {
    let empty = vector[];
    release_bid_reservations_except(state, registry, &empty);
}

fun release_all_allocation_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
) {
    let mut i = 0;
    let n = state.allocations.length();
    while (i < n) {
        solver_registry::release_stake(
            registry,
            solver_registry::allocation_reservation_key(state.current_epoch, i),
        );
        i = i + 1;
    };
}

fun release_all_benchmark_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
) {
    let pairs = state.pair_benchmarks.keys();
    let mut i = 0;
    let n = pairs.length();
    while (i < n) {
        let entry = state.pair_benchmarks.get(&pairs[i]);
        solver_registry::release_stake(
            registry,
            solver_registry::benchmark_reservation_key(state.current_epoch, entry.seq),
        );
        i = i + 1;
    };
}

fun release_all_open_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
) {
    release_all_bid_reservations(state, registry);
    release_all_allocation_reservations(state, registry);
    release_all_benchmark_reservations(state, registry);
}

// === Package accessors ===

public(package) fun assert_settlement_phase(state: &AuctionState) {
    assert!(phase_tag(&state.phase) == 3, EWrongPhase);
}

public(package) fun is_winner_intent(state: &AuctionState, id: &ID): bool {
    state.winner_intents.contains(id)
}

public(package) fun solver_of_intent(state: &AuctionState, id: &ID): address {
    *state.winner_solver_of.get(id)
}

public(package) fun reservation_of_intent(
    state: &AuctionState,
    id: &ID,
): StakeReservationKey {
    *state.winner_reservation_of.get(id)
}

public(package) fun floor_of_intent(state: &AuctionState, id: &ID): u64 {
    *state.intent_floor.get(id)
}

public(package) fun is_intent_settled(state: &AuctionState, id: &ID): bool {
    state.intent_settled.contains(id)
}

public(package) fun mark_intent_settled(state: &mut AuctionState, id: ID) {
    state.intent_settled.insert(id);
    if (state.batch.contains(&id)) { state.batch.remove(&id); };
}

public(package) fun committed_total_score(state: &AuctionState): u64 { state.committed_total_score }

public(package) fun current_epoch_score_surplus(state: &AuctionState): u64 {
    state.current_epoch_score_surplus
}

public(package) fun settled_intent_count(state: &AuctionState): u64 { state.settled_intent_count }

public(package) fun settled_score_value_sum(state: &AuctionState): u64 {
    state.settled_score_value_sum
}

public(package) fun winner_is_fallback(state: &AuctionState): bool { state.winner_is_fallback }

public(package) fun settlement_deadline_ms(state: &AuctionState): u64 {
    state.settlement_deadline_ms
}

public(package) fun record_settlement(
    state: &mut AuctionState,
    pair: PairKey,
    solver: address,
    payout: u64,
    floor: u64,
    score_value: u64,
    floor_value: u64,
) {
    if (state.pair_ratio_refs.contains(&pair)) {
        let r = state.pair_ratio_refs.get(&pair);
        assert!(
            math::cross_ratio_equal(payout, floor, r.payout_ref, r.floor_ref),
            EBidEpsrInconsistent,
        );
    } else {
        state.pair_ratio_refs.insert(pair, RatioRef { floor_ref: floor, payout_ref: payout });
    };
    state.current_epoch_score_surplus = state.current_epoch_score_surplus + score_value;
    state.settled_score_value_sum = state.settled_score_value_sum + floor_value;
    state.settled_intent_count = state.settled_intent_count + 1;
    if (state.solver_actual_score.contains(&solver)) {
        let s = state.solver_actual_score.get_mut(&solver);
        *s = *s + score_value;
    } else {
        state.solver_actual_score.insert(solver, score_value);
    };
}

public(package) fun actual_k_of_pair(state: &AuctionState, pair: &PairKey): u64 {
    let r = state.pair_ratio_refs.get(pair);
    math::fixed_ratio(r.payout_ref, r.floor_ref)
}

public(package) fun committed_k_of_pair(state: &AuctionState, pair: &PairKey): u64 {
    *state.committed_k_by_pair.get(pair)
}

public(package) fun committed_pairs(state: &AuctionState): vector<PairKey> {
    state.committed_k_by_pair.keys()
}

public(package) fun solver_actual_score(state: &AuctionState, solver: address): u64 {
    if (state.solver_actual_score.contains(&solver)) *state.solver_actual_score.get(&solver) else 0
}

public(package) fun winning_solver_list(state: &AuctionState): vector<address> {
    state.solver_actual_score.keys()
}

public(package) fun requeue_intent(
    state: &mut AuctionState,
    id: ID,
    pair: PairKey,
    min_amount_out: u64,
    sell_amount: u64,
    partial_fillable: bool,
    deadline: u64,
) {
    if (!state.requeued.contains(&id)) {
        state.requeued.insert(id);
        state
            .requeue_meta
            .insert(id, IntentMeta { pair, min_amount_out, sell_amount, partial_fillable, deadline });
    } else {
        let m = state.requeue_meta.get_mut(&id);
        *m = IntentMeta { pair, min_amount_out, sell_amount, partial_fillable, deadline };
    };
}

public(package) fun set_closed(state: &mut AuctionState, config: &GlobalConfig, clock: &Clock) {
    assert!(phase_tag(&state.phase) == 3, EWrongPhase);
    state.phase = AuctionPhase::Close;
    state.next_epoch_open_after_ms = clock.timestamp_ms() + config.min_batch_collect_ms();
    emit_phase(state, clock.timestamp_ms());
}

public(package) fun set_failed(state: &mut AuctionState, config: &GlobalConfig, clock: &Clock) {
    assert!(phase_tag(&state.phase) == 3, EWrongPhase);
    state.phase = AuctionPhase::Failed;
    state.next_epoch_open_after_ms = clock.timestamp_ms() + config.min_batch_collect_ms();
    events::emit_fallback_triggered(
        state.current_epoch,
        state.winner_intents.length() - state.intent_settled.length(),
    );
    emit_phase(state, clock.timestamp_ms());
}

public(package) fun winner_intent_ids(state: &AuctionState): vector<ID> {
    state.winner_intents.into_keys()
}

public(package) fun winning_reservation_keys(state: &AuctionState): vector<StakeReservationKey> {
    state.winning_reservations.into_keys()
}

public(package) fun all_winners_settled(state: &AuctionState): bool {
    state.intent_settled.length() >= state.winner_intents.length()
}

public(package) fun intent_meta_of(state: &AuctionState, id: &ID): (PairKey, u64, u64, bool, u64) {
    let m = state.intent_meta.get(id);
    (m.pair, m.min_amount_out, m.sell_amount, m.partial_fillable, m.deadline)
}

public(package) fun has_intent_meta(state: &AuctionState, id: &ID): bool {
    state.intent_meta.contains(id)
}

// === Test-only ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun submit_intent_with_price_for_testing<Sell, Buy>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    coin: Coin<Sell>,
    min_amount_out: u64,
    mid_price: u64,
    slippage_tolerance_bps: u64,
    sell_is_base: bool,
    partial_fillable: bool,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let floor = if (sell_is_base) {
        price_adapter::sbbo_floor_base_to_quote(coin.value(), mid_price, slippage_tolerance_bps)
    } else {
        price_adapter::sbbo_floor_quote_to_base(coin.value(), mid_price, slippage_tolerance_bps)
    };
    submit_intent_inner<Sell, Buy>(
        state,
        config,
        coin,
        min_amount_out,
        floor,
        mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        deadline,
        clock,
        ctx,
    )
}

#[test_only]
public fun set_phase_for_testing(
    state: &mut AuctionState,
    config: &GlobalConfig,
    clock: &Clock,
    target: u8,
) {
    while (phase_tag(&state.phase) != target) {
        let before = phase_tag(&state.phase);
        force_advance(state, config, clock);
        if (phase_tag(&state.phase) == before) break;
    };
}

#[test_only]
fun force_advance(state: &mut AuctionState, config: &GlobalConfig, _clock: &Clock) {
    let t = phase_tag(&state.phase);
    if (t == 0) {
        state.phase = AuctionPhase::Bid;
    } else if (t == 1) {
        state.phase = AuctionPhase::AllocationSelection;
    };
    let _ = config;
}
