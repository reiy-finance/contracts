// Copyright (c) Reiy Finance

/// Intent settlement, EPSR verification, dual close, net-safe rewards, and fallback slashing.
module reiy::settlement;

use deepbook::pool::Pool;
use reiy::auction::{Self, AuctionState};
use reiy::config::GlobalConfig;
use reiy::events;
use reiy::intent_book::{Self, Intent};
use reiy::math;
use reiy::price_adapter;
use reiy::solver_registry::{Self, SolverRegistry};
use reiy::treasury::{Self, ProtocolTreasury};
use reiy::types::{Self, PairKey};
use std::type_name;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;

// === Errors ===
#[error]
const ENotWinner: vector<u8> = b"caller is not the winning solver for this intent";
#[error]
const ENotInWinningSet: vector<u8> = b"intent is not in the winning set";
#[error]
const EAlreadySettled: vector<u8> = b"intent already settled this epoch";
#[error]
const EIntentExpired: vector<u8> = b"intent has expired";
#[error]
const EBelowMinimum: vector<u8> = b"payout below effective minimum";
#[error]
const EBelowFloor: vector<u8> = b"payout below benchmark floor";
#[error]
const EBadNumerairePool: vector<u8> = b"numeraire pool does not match buy token / allowlist";
#[error]
const ENotNumeraire: vector<u8> = b"buy token is not the configured numeraire";
#[error]
const EZeroSettlement: vector<u8> = b"no intents settled";
#[error]
const EScoreMismatch: vector<u8> = b"actual score below committed score";
#[error]
const EKMismatch: vector<u8> = b"actual k below committed k";
#[error]
const ENotAllSettled: vector<u8> = b"not all winning intents settled";
#[error]
const EFeeTooSmall: vector<u8> = b"protocol fee below required";
#[error]
const ETooEarly: vector<u8> = b"settlement deadline not yet passed";

/// Hot-potato receipt created by `take_intent_*` and consumed by `settle_*` in the same PTB.
/// * `intent_id`   - ID of the intent being settled
/// * `owner`       - Trader address that receives the buy-token payout
/// * `solver`      - Solver address that took the intent
/// * `pair`        - Directed pair of the intent
/// * `m_eff`       - Effective minimum buy amount (ceil proportional for partial fills)
/// * `floor`       - Benchmark floor `max(m_eff, bm_i)`; payout must meet or exceed this
/// * `sell_amount` - Amount of sell tokens extracted from the intent (for event emission)
public struct SettlementReceipt<phantom Sell, phantom Buy> {
    intent_id: ID,
    owner: address,
    solver: address,
    pair: PairKey,
    m_eff: u64,
    floor: u64,
    sell_amount: u64,
}

// === Take ===

/// Take a fully-filled winning intent. Consumes the intent, hands the solver the locked sell asset,
/// and returns a hot-potato receipt that MUST be consumed by a `settle_*` call in the same PTB.
public fun take_intent_full<Sell, Buy>(
    state: &mut AuctionState,
    intent: Intent<Sell, Buy>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    auction::assert_settlement_phase(state);
    let id = intent.intent_id();
    assert!(auction::is_winner_intent(state, &id), ENotInWinningSet);
    assert!(!auction::is_intent_settled(state, &id), EAlreadySettled);
    assert!(auction::solver_of_intent(state, &id) == ctx.sender(), ENotWinner);
    assert!(!intent.is_expired(clock), EIntentExpired);

    let pair = types::pair_key<Sell, Buy>();
    let floor = auction::floor_of_intent(state, &id);
    let (owner, balance, m_eff) = intent_book::consume_intent_full(intent);
    let sell_amount = balance.value();
    let receipt = SettlementReceipt<Sell, Buy> {
        intent_id: id,
        owner,
        solver: ctx.sender(),
        pair,
        m_eff,
        floor,
        sell_amount,
    };
    (coin::from_balance(balance, ctx), receipt)
}

/// Take a partially-filled winning intent. Splits `fill_amount` off the locked balance, advances the
/// intent to the next epoch, and re-queues its residual so it re-enters the next batch.
public fun take_intent_partial<Sell, Buy>(
    state: &mut AuctionState,
    intent: &mut Intent<Sell, Buy>,
    fill_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    auction::assert_settlement_phase(state);
    let id = intent.intent_id();
    assert!(auction::is_winner_intent(state, &id), ENotInWinningSet);
    assert!(!auction::is_intent_settled(state, &id), EAlreadySettled);
    assert!(auction::solver_of_intent(state, &id) == ctx.sender(), ENotWinner);
    assert!(!intent.is_expired(clock), EIntentExpired);

    let pair = types::pair_key<Sell, Buy>();
    let floor = auction::floor_of_intent(state, &id);
    let (owner, balance, m_eff) = intent_book::consume_intent_partial(intent, fill_amount);
    let sell_amount = balance.value();

    auction::requeue_intent(
        state,
        id,
        pair,
        intent.original_min_amount_out(),
        intent.original_sell_amount(),
        intent.partial_fillable(),
        intent.deadline(),
    );

    let receipt = SettlementReceipt<Sell, Buy> {
        intent_id: id,
        owner,
        solver: ctx.sender(),
        pair,
        m_eff,
        floor,
        sell_amount,
    };
    (coin::from_balance(balance, ctx), receipt)
}

// === Settle ===

/// Settle a winning intent whose BUY token IS the protocol numeraire.
public fun settle_intent_numeraire<Sell, Buy>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    config: &GlobalConfig,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
) {
    assert!(type_name::with_defining_ids<Buy>() == config.numeraire_type(), ENotNumeraire);
    let net = payout.value();
    let (raw_surplus, floor) = verify_payout(&receipt, net);
    finalize_settlement(state, registry, receipt, payout, raw_surplus, floor);
}

/// Settle a winning intent, normalizing its surplus into numeraire units using the allowlisted
/// `Buy/Numeraire` DeepBook pool.
public fun settle_intent<Sell, Buy, NumBase, NumQuote>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    config: &GlobalConfig,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    num_pool: &Pool<NumBase, NumQuote>,
    clock: &Clock,
) {
    let net = payout.value();
    let (raw_surplus, floor) = verify_payout(&receipt, net);

    let buy_t = type_name::with_defining_ids<Buy>();
    let expected = config.numeraire_pool_id(buy_t);
    assert!(expected.is_some() && *expected.borrow() == object::id(num_pool), EBadNumerairePool);

    let mid = price_adapter::read_mid_price(num_pool, config, clock);
    let (score_value, floor_value) = normalize_surplus<Buy, NumBase, NumQuote>(
        config,
        raw_surplus,
        floor,
        mid,
    );
    finalize_settlement_normalized(
        state,
        registry,
        receipt,
        payout,
        raw_surplus,
        floor,
        score_value,
        floor_value,
    );
}

fun verify_payout<Sell, Buy>(receipt: &SettlementReceipt<Sell, Buy>, net: u64): (u64, u64) {
    assert!(net >= receipt.m_eff, EBelowMinimum);
    assert!(net >= receipt.floor, EBelowFloor);
    (net - receipt.floor, receipt.floor)
}

fun normalize_surplus<Buy, NumBase, NumQuote>(
    config: &GlobalConfig,
    raw_surplus: u64,
    floor: u64,
    mid: u64,
): (u64, u64) {
    let buy_t = type_name::with_defining_ids<Buy>();
    let nb = type_name::with_defining_ids<NumBase>();
    let nq = type_name::with_defining_ids<NumQuote>();
    let num = config.numeraire_type();
    if (buy_t == nb) {
        assert!(nq == num, EBadNumerairePool);
        (
            price_adapter::normalize_base_to_quote(raw_surplus, mid),
            price_adapter::normalize_base_to_quote(floor, mid),
        )
    } else {
        assert!(buy_t == nq, EBadNumerairePool);
        assert!(nb == num, EBadNumerairePool);
        (
            price_adapter::normalize_quote_to_base(raw_surplus, mid),
            price_adapter::normalize_quote_to_base(floor, mid),
        )
    }
}

fun finalize_settlement<Sell, Buy>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    raw_surplus: u64,
    floor: u64,
) {
    // buy == numeraire: surplus/floor already in numeraire units
    finalize_settlement_normalized(
        state,
        registry,
        receipt,
        payout,
        raw_surplus,
        floor,
        raw_surplus,
        floor,
    );
}

fun finalize_settlement_normalized<Sell, Buy>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    raw_surplus: u64,
    floor: u64,
    score_value: u64,
    floor_value: u64,
) {
    let SettlementReceipt { intent_id, owner, solver, pair, m_eff: _, floor: _, sell_amount } =
        receipt;
    let net = payout.value();
    auction::record_settlement(
        state,
        pair,
        solver,
        net,
        floor,
        score_value,
        floor_value,
    );
    auction::mark_intent_settled(state, intent_id);
    solver_registry::record_settled(registry, solver, net);

    let epoch = auction::current_epoch(state);
    events::emit_settlement(
        intent_id,
        solver,
        epoch,
        sell_amount,
        net,
        raw_surplus,
        score_value,
        events::settle_cow(),
    );

    transfer::public_transfer(payout, owner);
}

// === Close ===

/// Close the batch: dual verification (score + per-pair k), fee collection, and reward distribution.
/// All winning intents must be settled before calling.
#[allow(lint(self_transfer))]
public fun close_batch<N>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    treasury: &mut ProtocolTreasury<N>,
    mut fee: Coin<N>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    auction::assert_settlement_phase(state);
    assert!(auction::all_winners_settled(state), ENotAllSettled);

    let settled = auction::settled_intent_count(state);
    assert!(settled > 0, EZeroSettlement);

    let actual_score = auction::current_epoch_score_surplus(state);
    let committed_score = auction::committed_total_score(state);
    assert!(actual_score >= committed_score, EScoreMismatch);

    let pairs = auction::committed_pairs(state);
    let mut i = 0;
    let np = pairs.length();
    while (i < np) {
        let pair = pairs[i];
        let actual_k = auction::actual_k_of_pair(state, &pair);
        let committed_k = auction::committed_k_of_pair(state, &pair);
        assert!(actual_k >= committed_k, EKMismatch);
        i = i + 1;
    };

    let epoch = auction::current_epoch(state);
    let value_sum = auction::settled_score_value_sum(state);

    let required_fee = math::mul_div_floor(value_sum, config.protocol_fee_bps(), math::bps_denom());
    assert!(fee.value() >= required_fee, EFeeTooSmall);
    // deposit only the required fee; refund any overpayment to the caller
    let exact = fee.split(required_fee, ctx);
    treasury::deposit_fee(treasury, exact, epoch);
    if (fee.value() > 0) {
        transfer::public_transfer(fee, ctx.sender());
    } else {
        fee.destroy_zero();
    };

    distribute_rewards(state, config, treasury, actual_score, value_sum, ctx);

    events::emit_settlement_complete(
        epoch,
        actual_score,
        committed_score,
        settled,
        value_sum,
    );

    auction::set_closed(state, config, clock);
}

fun distribute_rewards<N>(
    state: &AuctionState,
    config: &GlobalConfig,
    treasury: &mut ProtocolTreasury<N>,
    actual_score: u64,
    value_sum: u64,
    ctx: &mut TxContext,
) {
    if (actual_score == 0) return;
    let by_share = math::mul_div_floor(actual_score, config.reward_share_bps(), math::bps_denom());
    let by_cap = math::mul_div_floor(value_sum, config.reward_cap_bps(), math::bps_denom());
    let avail = treasury::balance(treasury);
    let mut total_reward = if (by_share < by_cap) by_share else by_cap;
    if (total_reward > avail) total_reward = avail;
    if (total_reward == 0) return;

    let solvers = auction::winning_solver_list(state);
    let mut i = 0;
    let n = solvers.length();
    while (i < n) {
        let s = solvers[i];
        let s_score = auction::solver_actual_score(state, s);
        let amount = math::mul_div_floor(total_reward, s_score, actual_score);
        if (amount > 0) {
            let reward = treasury::withdraw_reward(treasury, amount, ctx);
            transfer::public_transfer(reward, s);
        };
        i = i + 1;
    };
}

// === Fallback ===

/// Permissionless fallback after the settlement deadline. A solver is slashed only for intents that
/// were still settleable (not expired) yet left unsettled — i.e. genuine solver fault. Intents that
/// expired before settlement are neither slashed nor re-queued; the owner reclaims them via cancel.
/// Still-valid unsettled intents are re-queued for the next epoch. The epoch moves to Failed.
#[allow(lint(self_transfer))]
public fun trigger_fallback(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    config: &GlobalConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    auction::assert_settlement_phase(state);
    let now = clock.timestamp_ms();
    assert!(now > auction::settlement_deadline_ms(state), ETooEarly);

    let ids = auction::winner_intent_ids(state);
    let mut slashed = sui::balance::zero<SUI>();
    let mut slashed_solvers = sui::vec_set::empty<address>();

    let mut i = 0;
    let n = ids.length();
    while (i < n) {
        let id = ids[i];
        if (!auction::is_intent_settled(state, &id) && auction::has_intent_meta(state, &id)) {
            let (pair, min_out, sell_amount, partial, deadline) = auction::intent_meta_of(state, &id);
            // Expired intents were impossible to settle: do not slash, do not re-queue.
            if (now <= deadline) {
                let solver = auction::solver_of_intent(state, &id);
                if (
                    !slashed_solvers.contains(&solver) && solver_registry::is_registered(registry, solver)
                ) {
                    slashed_solvers.insert(solver);
                    let amount = solver_registry::bond_of(registry, solver);
                    if (amount > 0) {
                        let b = solver_registry::slash(
                            registry,
                            solver,
                            amount,
                            solver_registry::reason_timeout(),
                            ctx,
                        );
                        slashed.join(b);
                    };
                };
                auction::requeue_intent(state, id, pair, min_out, sell_amount, partial, deadline);
            };
        };
        i = i + 1;
    };

    auction::set_failed(state, config, clock);

    if (slashed.value() > 0) {
        transfer::public_transfer(coin::from_balance(slashed, ctx), ctx.sender());
    } else {
        slashed.destroy_zero();
    };
}

// === Test-only settle (inject normalized values, no DeepBook) ===

#[test_only]
public fun settle_intent_with_values_for_testing<Sell, Buy>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    score_value: u64,
    floor_value: u64,
) {
    let net = payout.value();
    let (raw_surplus, floor) = verify_payout(&receipt, net);
    finalize_settlement_normalized(
        state,
        registry,
        receipt,
        payout,
        raw_surplus,
        floor,
        score_value,
        floor_value,
    );
}
