// Copyright (c) Reiy Finance

/// Slim protocol state for the hybrid model: intents escrow on-chain, while bid collection,
/// scoring, winner selection, and retry orchestration live in the Execution Coordinator.
module reiy::auction;

use deepbook::pool::Pool;
use reiy::config::GlobalConfig;
use reiy::events;
use reiy::intent_book::{Self, Intent};
use reiy::price_adapter;
use reiy::types;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::vec_set::{Self, VecSet};

#[error]
const ESlippageTooHigh: vector<u8> = b"slippage tolerance exceeds configured max";
#[error]
const EEpochTooEarly: vector<u8> = b"epoch cannot advance yet";
#[error]
const EIntentAlreadyFilledThisEpoch: vector<u8> = b"intent already filled in this epoch";

public struct AuctionState has key {
    id: UID,
    current_epoch: u64,
    epoch_started_ms: u64,
    partial_filled_intents: VecSet<ID>,
    settled_intent_count: u64,
    total_volume_fee: u64,
    total_surplus_fee: u64,
    total_protocol_fee: u64,
    total_solver_fee: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(new_state(ctx));
}

fun new_state(ctx: &mut TxContext): AuctionState {
    AuctionState {
        id: object::new(ctx),
        current_epoch: 0,
        epoch_started_ms: 0,
        partial_filled_intents: vec_set::empty(),
        settled_intent_count: 0,
        total_volume_fee: 0,
        total_surplus_fee: 0,
        total_protocol_fee: 0,
        total_solver_fee: 0,
    }
}

public fun id(s: &AuctionState): ID { object::id(s) }

public fun current_epoch(s: &AuctionState): u64 { s.current_epoch }

public fun epoch_started_ms(s: &AuctionState): u64 { s.epoch_started_ms }

/// Kept as a tiny compatibility surface for indexers that displayed the old phase code.
/// The hybrid protocol has no on-chain bid/selection phases, so the live phase is always
/// IntentCollection (0).
public fun phase_code(_s: &AuctionState): u8 { 0 }

public fun is_settlement(_s: &AuctionState): bool { true }

public fun settled_intent_count(s: &AuctionState): u64 { s.settled_intent_count }

public fun total_volume_fee(s: &AuctionState): u64 { s.total_volume_fee }

public fun total_surplus_fee(s: &AuctionState): u64 { s.total_surplus_fee }

public fun total_protocol_fee(s: &AuctionState): u64 { s.total_protocol_fee }

public fun total_solver_fee(s: &AuctionState): u64 { s.total_solver_fee }

public fun was_partial_filled_this_epoch(s: &AuctionState, id: &ID): bool {
    s.partial_filled_intents.contains(id)
}

public fun advance_epoch(state: &mut AuctionState, config: &GlobalConfig, clock: &Clock) {
    let now = clock.timestamp_ms();
    assert!(now >= state.epoch_started_ms + config.min_batch_collect_ms(), EEpochTooEarly);
    state.current_epoch = state.current_epoch + 1;
    state.epoch_started_ms = now;
    state.partial_filled_intents = vec_set::empty();
    events::emit_epoch_advanced(state.current_epoch, 0, now);
}

// === Intent submission ===

public fun submit_intent_sell_base<Base, Quote>(
    state: &AuctionState,
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

public fun submit_intent_sell_quote<Base, Quote>(
    state: &AuctionState,
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
    state: &AuctionState,
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
    assert!(slippage_tolerance_bps <= config.max_slippage_tolerance_bps(), ESlippageTooHigh);
    let pair = types::pair_key<Sell, Buy>();
    config.assert_pair_supported(&pair);
    intent_book::create_intent<Sell, Buy>(
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
    )
}

public fun cancel_intent<Sell, Buy>(
    _state: &AuctionState,
    intent: Intent<Sell, Buy>,
    ctx: &mut TxContext,
) {
    intent_book::cancel_intent(intent, ctx);
}

// === Settlement hooks ===

public(package) fun assert_not_partial_filled_this_epoch(state: &AuctionState, id: &ID) {
    assert!(!state.partial_filled_intents.contains(id), EIntentAlreadyFilledThisEpoch);
}

public(package) fun mark_partial_filled(state: &mut AuctionState, id: ID) {
    state.partial_filled_intents.insert(id);
}

public(package) fun record_settlement(
    state: &mut AuctionState,
    volume_fee: u64,
    surplus_fee: u64,
    protocol_fee: u64,
    solver_fee: u64,
) {
    state.settled_intent_count = state.settled_intent_count + 1;
    state.total_volume_fee = state.total_volume_fee + volume_fee;
    state.total_surplus_fee = state.total_surplus_fee + surplus_fee;
    state.total_protocol_fee = state.total_protocol_fee + protocol_fee;
    state.total_solver_fee = state.total_solver_fee + solver_fee;
}

#[test_only]
public fun submit_intent_with_price_for_testing<Sell, Buy>(
    state: &AuctionState,
    config: &GlobalConfig,
    coin: Coin<Sell>,
    min_amount_out: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    sell_base: bool,
    partial_fillable: bool,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let floor = if (sell_base) {
        price_adapter::sbbo_floor_base_to_quote(coin.value(), sbbo_mid_price, slippage_tolerance_bps)
    } else {
        price_adapter::sbbo_floor_quote_to_base(coin.value(), sbbo_mid_price, slippage_tolerance_bps)
    };
    submit_intent_inner<Sell, Buy>(
        state,
        config,
        coin,
        min_amount_out,
        floor,
        sbbo_mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        deadline,
        clock,
        ctx,
    )
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
