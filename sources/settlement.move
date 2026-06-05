// Copyright (c) Reiy Finance

/// Intent settlement, fallback slashing. Fees are split from Coin<Buy> per settlement;
/// close_batch only verifies score/UCP and releases reservations.
module reiy::settlement;

use deepbook::pool::Pool;
use reiy::auction::{Self, AuctionState};
use reiy::config::GlobalConfig;
use reiy::events;
use reiy::fee_vault::{Self, FeeVault};
use reiy::intent_book::{Self, Intent};
use reiy::math;
use reiy::price_adapter;
use reiy::solver_registry::{Self, SolverRegistry, StakeReservationKey};
use reiy::treasury::{Self, ProtocolTreasury};
use reiy::types::{Self, PairKey};
use std::type_name;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::vec_set::VecSet;

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
const EBelowFloor: vector<u8> = b"payout below benchmark floor (after volume fee)";
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
const ETooEarly: vector<u8> = b"settlement deadline not yet passed";
#[error]
const ESettlementDeadlinePassed: vector<u8> = b"settlement deadline has passed";
#[error]
const EAllWinnersSettled: vector<u8> = b"all winning intents already settled";
#[error]
const ETreasuryNumeraireMismatch: vector<u8> = b"treasury numeraire does not match config";

/// Receipt created by `take_intent_*` and consumed by `settle_*` in the same PTB.
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

/// Take a fully-filled winning intent.
public fun take_intent_full<Sell, Buy>(
    state: &mut AuctionState,
    intent: Intent<Sell, Buy>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    auction::assert_settlement_phase(state);
    assert_settlement_deadline_open(state, clock);
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

/// Take a partially-filled winning intent and requeue the residual.
public fun take_intent_partial<Sell, Buy>(
    state: &mut AuctionState,
    intent: &mut Intent<Sell, Buy>,
    fill_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    auction::assert_settlement_phase(state);
    assert_settlement_deadline_open(state, clock);
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
/// Fees are split from `payout: Coin<Buy>` and deposited into `fee_vault`.
public fun settle_intent_numeraire<Sell, Buy, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    fee_vault: &mut FeeVault<Buy>,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    ctx: &mut TxContext,
) {
    assert_solver_registry(config, registry);
    assert!(type_name::with_defining_ids<Buy>() == config.numeraire_type(), ENotNumeraire);
    fee_vault::assert_canonical<Buy>(config, fee_vault);

    let gross = payout.value();
    let protected_min = max_u64(receipt.m_eff, receipt.floor);
    let (volume_fee, surplus_fee, total_fee) = compute_fees(config, &receipt.pair, gross, protected_min);
    let net = gross - total_fee;

    finalize_settlement(
        state, registry, config, fee_vault, receipt, payout,
        gross, protected_min, volume_fee, surplus_fee, total_fee, net,
        // score_value = created_surplus in numeraire units (Buy == N)
        gross - protected_min,
        protected_min,
        ctx,
    );
}

/// Settle a winning intent, normalizing surplus into numeraire units using the allowlisted
/// `Buy/Numeraire` DeepBook pool.
public fun settle_intent<Sell, Buy, NumBase, NumQuote, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    fee_vault: &mut FeeVault<Buy>,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    num_pool: &Pool<NumBase, NumQuote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_solver_registry(config, registry);
    fee_vault::assert_canonical<Buy>(config, fee_vault);

    let buy_t = type_name::with_defining_ids<Buy>();
    let expected = config.numeraire_pool_id(buy_t);
    assert!(expected.is_some() && *expected.borrow() == object::id(num_pool), EBadNumerairePool);

    let gross = payout.value();
    let protected_min = max_u64(receipt.m_eff, receipt.floor);
    let (volume_fee, surplus_fee, total_fee) = compute_fees(config, &receipt.pair, gross, protected_min);
    let net = gross - total_fee;

    let mid = price_adapter::read_mid_price(num_pool, config, clock);
    let (score_value, floor_value) = normalize_surplus<Buy, NumBase, NumQuote>(
        config,
        gross - protected_min, // created_surplus in Buy
        protected_min,
        mid,
    );

    finalize_settlement(
        state, registry, config, fee_vault, receipt, payout,
        gross, protected_min, volume_fee, surplus_fee, total_fee, net,
        score_value,
        floor_value,
        ctx,
    );
}

// === Fee computation ===

/// Returns (volume_fee, surplus_fee, total_fee) all in Buy token units.
fun compute_fees(config: &GlobalConfig, pair: &PairKey, gross: u64, protected_min: u64): (u64, u64, u64) {
    let vol_ppm = config.volume_fee_ppm_for_pair(pair);
    let volume_fee = math::mul_div_floor(gross, vol_ppm, math::ppm_denom());
    let payout_after_volume = gross - volume_fee;

    assert!(payout_after_volume >= protected_min, EBelowFloor);

    let surplus_after_volume = payout_after_volume - protected_min;
    let surplus_fee_by_share = math::mul_div_floor(surplus_after_volume, config.surplus_fee_ppm(), math::ppm_denom());
    let surplus_fee_by_cap = math::mul_div_floor(gross, config.surplus_fee_cap_ppm(), math::ppm_denom());
    let surplus_fee = if (surplus_fee_by_share < surplus_fee_by_cap) surplus_fee_by_share else surplus_fee_by_cap;

    let total_uncapped = volume_fee + surplus_fee;
    let total_cap = math::mul_div_floor(gross, config.max_total_fee_ppm(), math::ppm_denom());
    let total_fee = if (total_uncapped < total_cap) total_uncapped else total_cap;

    (volume_fee, surplus_fee, total_fee)
}

fun max_u64(a: u64, b: u64): u64 { if (a >= b) a else b }

fun normalize_surplus<Buy, NumBase, NumQuote>(
    config: &GlobalConfig,
    created_surplus: u64,
    protected_min: u64,
    mid: u64,
): (u64, u64) {
    let buy_t = type_name::with_defining_ids<Buy>();
    let nb = type_name::with_defining_ids<NumBase>();
    let nq = type_name::with_defining_ids<NumQuote>();
    let num = config.numeraire_type();
    if (buy_t == nb) {
        assert!(nq == num, EBadNumerairePool);
        (
            price_adapter::normalize_base_to_quote(created_surplus, mid),
            price_adapter::normalize_base_to_quote(protected_min, mid),
        )
    } else {
        assert!(buy_t == nq, EBadNumerairePool);
        assert!(nb == num, EBadNumerairePool);
        (
            price_adapter::normalize_quote_to_base(created_surplus, mid),
            price_adapter::normalize_quote_to_base(protected_min, mid),
        )
    }
}

fun assert_settlement_deadline_open(state: &AuctionState, clock: &Clock) {
    assert!(clock.timestamp_ms() <= auction::settlement_deadline_ms(state), ESettlementDeadlinePassed);
}

fun assert_solver_registry<Stake>(config: &GlobalConfig, registry: &SolverRegistry<Stake>) {
    config.assert_solver_registry_id(solver_registry::id(registry));
}

fun assert_treasury<N, Stake>(
    config: &GlobalConfig,
    treasury: &ProtocolTreasury<N, Stake>,
) {
    assert!(type_name::with_defining_ids<N>() == config.numeraire_type(), ETreasuryNumeraireMismatch);
    config.assert_protocol_treasury_id(treasury::id(treasury));
}

#[allow(lint(self_transfer))]
fun finalize_settlement<Sell, Buy, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    _config: &GlobalConfig,
    fee_vault: &mut FeeVault<Buy>,
    receipt: SettlementReceipt<Sell, Buy>,
    mut payout: Coin<Buy>,
    gross: u64,
    protected_min: u64,
    volume_fee: u64,
    surplus_fee: u64,
    total_fee: u64,
    net: u64,
    score_value: u64,
    floor_value: u64,
    ctx: &mut TxContext,
) {
    let SettlementReceipt { intent_id, owner, solver, pair, m_eff: _, floor: _, sell_amount } = receipt;

    // gross must be >= both m_eff and floor before fee; EBelowFloor already checked in compute_fees
    // EBelowMinimum: gross >= m_eff check (floor check covered by compute_fees)
    assert!(gross >= net + total_fee, EBelowMinimum); // always true, structural guard

    let epoch = auction::current_epoch(state);

    // Split fee from payout coin and deposit into vault; accumulate for close-time reward calc
    let fee_coin = payout.split(total_fee, ctx);
    fee_vault::deposit_fee(fee_vault, fee_coin, epoch);
    auction::accumulate_batch_fee(state, total_fee);

    // Record settlement with UCP ref (gross/sell_amount)
    auction::record_settlement(state, pair, solver, gross, sell_amount, score_value, floor_value);
    auction::mark_intent_settled(state, intent_id);
    solver_registry::record_settled(registry, solver, gross);

    let created_surplus = gross - protected_min;
    let net_user_surplus = if (net > protected_min) net - protected_min else 0;

    events::emit_settlement_fee_charged(
        intent_id,
        solver,
        epoch,
        gross,
        protected_min,
        volume_fee,
        surplus_fee,
        total_fee,
        net,
        created_surplus,
        net_user_surplus,
        type_name::with_defining_ids<Buy>(),
    );
    events::emit_settlement(
        intent_id,
        solver,
        epoch,
        sell_amount,
        net,
        created_surplus,
        score_value,
        events::settle_cow(),
    );

    transfer::public_transfer(payout, owner);
}

// === Close ===

/// Close the batch: verify score and UCP k, distribute VCG solver rewards from fee vault,
/// release winning reservations, advance to Close phase.
/// `N` must be the protocol numeraire (the token type of the fee vault).
#[allow(lint(self_transfer))]
public fun close_batch<N, Stake>(
    state: &mut AuctionState,
    config: &GlobalConfig,
    registry: &mut SolverRegistry<Stake>,
    fee_vault: &mut FeeVault<N>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    auction::assert_settlement_phase(state);
    assert_solver_registry(config, registry);
    assert!(type_name::with_defining_ids<N>() == config.numeraire_type(), ETreasuryNumeraireMismatch);
    fee_vault::assert_canonical<N>(config, fee_vault);
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

    // VCG-style solver reward: performanceReward = cap(actual - benchmark, β × fees)
    // Distributed proportionally to each solver by their verified score contribution.
    distribute_solver_rewards<N>(state, config, fee_vault, epoch, actual_score, ctx);

    release_winning_reservations(state, registry);

    events::emit_settlement_complete(
        epoch,
        actual_score,
        committed_score,
        settled,
        value_sum,
    );

    auction::set_closed(state, config, clock);
}

fun distribute_solver_rewards<N>(
    state: &AuctionState,
    config: &GlobalConfig,
    fee_vault: &mut FeeVault<N>,
    epoch: u64,
    actual_score: u64,
    ctx: &mut TxContext,
) {
    let reward_share_ppm = config.solver_reward_fee_share_ppm();
    if (reward_share_ppm == 0) return;

    let total_fee = auction::batch_total_fee_collected(state);
    if (total_fee == 0) return;

    let benchmark_score = auction::committed_benchmark_score(state);
    let performance_excess =
        if (actual_score > benchmark_score) actual_score - benchmark_score else 0;
    if (performance_excess == 0) return;

    let reward_cap = math::mul_div_floor(total_fee, reward_share_ppm, math::ppm_denom());
    let total_reward = if (performance_excess < reward_cap) performance_excess else reward_cap;
    if (total_reward == 0) return;

    let solvers = auction::winning_solver_list(state);
    let ns = solvers.length();
    if (ns == 0) return;

    let fee_token = type_name::with_defining_ids<N>();
    let mut si = 0;
    while (si < ns) {
        let solver = solvers[si];
        let solver_score = auction::solver_actual_score(state, solver);
        let solver_reward = math::mul_div_floor(total_reward, solver_score, actual_score);
        if (solver_reward > 0 && fee_vault::balance(fee_vault) >= solver_reward) {
            let reward_coin = fee_vault::pay_reward(fee_vault, solver_reward, ctx);
            transfer::public_transfer(reward_coin, solver);
            events::emit_solver_reward_paid(
                epoch, solver, solver_reward, performance_excess, reward_cap, fee_token,
            );
        };
        si = si + 1;
    };
}

fun release_winning_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
) {
    let keys = auction::winning_reservation_keys(state);
    let mut i = 0;
    let n = keys.length();
    while (i < n) {
        solver_registry::release_stake(registry, keys[i]);
        i = i + 1;
    };
}

fun release_unslashed_winning_reservations<Stake>(
    state: &AuctionState,
    registry: &mut SolverRegistry<Stake>,
    slashed: &VecSet<StakeReservationKey>,
) {
    let keys = auction::winning_reservation_keys(state);
    let mut i = 0;
    let n = keys.length();
    while (i < n) {
        let key = keys[i];
        if (!slashed.contains(&key)) {
            solver_registry::release_stake(registry, key);
        };
        i = i + 1;
    };
}

// === Fallback ===

/// Fallback failed settlement: requeues valid unsettled intents, slashes faulted reservations.
/// Treasury is still required here for slashed stake deposits.
#[allow(lint(self_transfer))]
public fun trigger_fallback<N, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    treasury: &mut ProtocolTreasury<N, Stake>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    auction::assert_settlement_phase(state);
    let now = clock.timestamp_ms();
    assert!(now > auction::settlement_deadline_ms(state), ETooEarly);
    assert!(!auction::all_winners_settled(state), EAllWinnersSettled);
    assert_solver_registry(config, registry);
    assert_treasury(config, treasury);

    let ids = auction::winner_intent_ids(state);
    let mut slashed = sui::balance::zero<Stake>();
    let mut slashed_reservations = sui::vec_set::empty<StakeReservationKey>();
    let mut slashed_owners = sui::vec_set::empty<address>();

    let mut i = 0;
    let n = ids.length();
    while (i < n) {
        let id = ids[i];
        if (!auction::is_intent_settled(state, &id) && auction::has_intent_meta(state, &id)) {
            let (pair, min_out, sell_amount, partial, deadline) = auction::intent_meta_of(state, &id);
            if (now <= deadline) {
                let reservation_key = auction::reservation_of_intent(state, &id);
                if (
                    !slashed_reservations.contains(&reservation_key)
                    && solver_registry::has_reservation(registry, reservation_key)
                ) {
                    let owner = solver_registry::reservation_owner(registry, reservation_key);
                    slashed_reservations.insert(reservation_key);
                    if (!slashed_owners.contains(&owner)) slashed_owners.insert(owner);
                    let b = solver_registry::slash_reserved_stake(
                        registry,
                        reservation_key,
                        solver_registry::reason_timeout(),
                        ctx,
                    );
                    slashed.join(b);
                };
                auction::requeue_intent(state, id, pair, min_out, sell_amount, partial, deadline);
            };
        };
        i = i + 1;
    };

    auction::set_failed(state, config, clock);

    release_unslashed_winning_reservations(state, registry, &slashed_reservations);

    if (slashed.value() > 0) {
        let total = slashed.value();
        let bounty = if (slashed_owners.contains(&ctx.sender())) {
            0
        } else {
            math::mul_div_floor(total, config.fallback_bounty_bps(), math::bps_denom())
        };
        let mut stake = coin::from_balance(slashed, ctx);
        if (bounty > 0) {
            let bounty_coin = stake.split(bounty, ctx);
            treasury::record_fallback_bounty(treasury, bounty);
            transfer::public_transfer(bounty_coin, ctx.sender());
        };
        if (stake.value() > 0) {
            treasury::deposit_slashed_stake(treasury, stake, total, auction::current_epoch(state));
        } else {
            stake.destroy_zero();
        };
    } else {
        slashed.destroy_zero();
    };
}

// === Test-only settle (inject normalized values, no DeepBook, no fee split) ===

#[test_only]
public fun settle_intent_with_values_for_testing<Sell, Buy, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    fee_vault: &mut FeeVault<Buy>,
    receipt: SettlementReceipt<Sell, Buy>,
    payout: Coin<Buy>,
    score_value: u64,
    floor_value: u64,
    ctx: &mut TxContext,
) {
    fee_vault::assert_canonical<Buy>(config, fee_vault);
    let gross = payout.value();
    let protected_min = max_u64(receipt.m_eff, receipt.floor);
    assert!(gross >= receipt.m_eff, EBelowMinimum);
    let (volume_fee, surplus_fee, total_fee) = compute_fees(config, &receipt.pair, gross, protected_min);
    let net = gross - total_fee;
    finalize_settlement(
        state, registry, config, fee_vault, receipt, payout,
        gross, protected_min, volume_fee, surplus_fee, total_fee, net,
        score_value,
        floor_value,
        ctx,
    );
}
