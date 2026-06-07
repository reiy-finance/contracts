// Copyright (c) Reiy Finance

/// Certificate-based settlement for the hybrid model. The Execution Coordinator chooses and signs
/// solutions off-chain; this module verifies the certificate and enforces each user's on-chain
/// protection before any escrowed sell asset can leave an Intent.
module reiy::settlement;

use deepbook::pool::Pool;
use reiy::auction::{Self, AuctionState};
use reiy::config::GlobalConfig;
use reiy::events;
use reiy::fee_vault::{Self, FeeVault};
use reiy::intent_book::{Self, Intent};
use reiy::math;
use reiy::price_adapter;
use reiy::solver_registry::{Self, SolverRegistry};
use reiy::types::{Self, PairKey};
use std::bcs;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::ed25519;

#[error]
const ENotAuthorizedSolver: vector<u8> = b"caller is not the certificate solver";
#[error]
const ESolverNotActive: vector<u8> = b"solver not registered/active";
#[error]
const EBadSolutionSignature: vector<u8> = b"invalid execution coordinator signature";
#[error]
const EBadCoordinatorKey: vector<u8> = b"execution coordinator key not configured";
#[error]
const EExpiredSolution: vector<u8> = b"solution certificate expired";
#[error]
const ELengthMismatch: vector<u8> = b"solution vector length mismatch";
#[error]
const EEmptySolution: vector<u8> = b"solution must include at least one intent";
#[error]
const EIntentMismatch: vector<u8> = b"intent does not match next authorized solution entry";
#[error]
const EAuthExhausted: vector<u8> = b"solution authorization exhausted";
#[error]
const EWrongEpoch: vector<u8> = b"intent target epoch does not match solution epoch";
#[error]
const EIntentExpired: vector<u8> = b"intent has expired";
#[error]
const EZeroFill: vector<u8> = b"fill amount must be > 0";
#[error]
const EFullFillMismatch: vector<u8> = b"full fill must consume the whole remaining intent";
#[error]
const EBelowProtectedMinimum: vector<u8> = b"certificate protected minimum below intent minimum";
#[error]
const EBadGrossPayout: vector<u8> = b"payout does not match certificate gross payout";
#[error]
const EBelowFloor: vector<u8> = b"payout below protected minimum after volume fee";
#[error]
const EBadNumerairePool: vector<u8> = b"numeraire pool does not match buy token / allowlist";
#[error]
const ENotNumeraire: vector<u8> = b"buy token is not the configured numeraire";
#[error]
const ETokenMismatch: vector<u8> = b"solution token types do not match settlement call";

public struct SolutionMessage has copy, drop {
    protocol_state_id: ID,
    config_id: ID,
    key_version: u64,
    epoch: u64,
    solution_id: vector<u8>,
    solver: address,
    sell_type: TypeName,
    buy_type: TypeName,
    intent_ids: vector<ID>,
    fills: vector<u64>,
    gross_payouts: vector<u64>,
    protected_mins: vector<u64>,
    expires_at_ms: u64,
}

public struct SolutionAuth<phantom Sell, phantom Buy> has drop {
    solution_id: vector<u8>,
    solver: address,
    epoch: u64,
    intent_ids: vector<ID>,
    fills: vector<u64>,
    gross_payouts: vector<u64>,
    protected_mins: vector<u64>,
    next: u64,
}

public struct SettlementReceipt<phantom Sell, phantom Buy> {
    intent_id: ID,
    owner: address,
    solver: address,
    pair: PairKey,
    gross_payout: u64,
    protected_min: u64,
    m_eff: u64,
    sell_amount: u64,
}

public fun verify_solution<Sell, Buy>(
    state: &AuctionState,
    config: &GlobalConfig,
    solution_id: vector<u8>,
    solver: address,
    intent_ids: vector<ID>,
    fills: vector<u64>,
    gross_payouts: vector<u64>,
    protected_mins: vector<u64>,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): SolutionAuth<Sell, Buy> {
    assert!(ctx.sender() == solver, ENotAuthorizedSolver);
    assert!(clock.timestamp_ms() <= expires_at_ms, EExpiredSolution);
    assert_solution_vectors(&intent_ids, &fills, &gross_payouts, &protected_mins);

    let message = SolutionMessage {
        protocol_state_id: auction::id(state),
        config_id: config.id(),
        key_version: config.execution_coordinator_key_version(),
        epoch: auction::current_epoch(state),
        solution_id,
        solver,
        sell_type: type_name::with_defining_ids<Sell>(),
        buy_type: type_name::with_defining_ids<Buy>(),
        intent_ids,
        fills,
        gross_payouts,
        protected_mins,
        expires_at_ms,
    };
    assert!(message.sell_type == type_name::with_defining_ids<Sell>(), ETokenMismatch);
    assert!(message.buy_type == type_name::with_defining_ids<Buy>(), ETokenMismatch);

    let pubkey = config.execution_coordinator_pubkey();
    assert!(pubkey.length() == 32, EBadCoordinatorKey);
    let bytes = bcs::to_bytes(&message);
    assert!(ed25519::ed25519_verify(&signature, pubkey, &bytes), EBadSolutionSignature);

    let SolutionMessage {
        protocol_state_id: _,
        config_id: _,
        key_version: _,
        epoch,
        solution_id,
        solver,
        sell_type: _,
        buy_type: _,
        intent_ids,
        fills,
        gross_payouts,
        protected_mins,
        expires_at_ms: _,
    } = message;
    events::emit_solution_authorized(epoch, solution_id, solver, intent_ids.length());
    SolutionAuth<Sell, Buy> {
        solution_id,
        solver,
        epoch,
        intent_ids,
        fills,
        gross_payouts,
        protected_mins,
        next: 0,
    }
}

public fun take_authorized_intent_full<Sell, Buy>(
    state: &mut AuctionState,
    auth: &mut SolutionAuth<Sell, Buy>,
    intent: Intent<Sell, Buy>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    let (expected_id, fill, gross_payout, protected_min) = next_authorized(auth);
    let id = intent.intent_id();
    assert!(id == expected_id, EIntentMismatch);
    assert!(intent.target_epoch() == auth.epoch, EWrongEpoch);
    assert!(!intent.is_expired(clock), EIntentExpired);
    auction::assert_not_partial_filled_this_epoch(state, &id);
    let remaining = intent.remaining_sell();
    assert!(fill == remaining, EFullFillMismatch);
    assert!(protected_min >= intent.min_amount_out(), EBelowProtectedMinimum);

    let pair = types::pair_key<Sell, Buy>();
    let (owner, balance, m_eff) = intent_book::consume_intent_full(intent);
    assert!(protected_min >= m_eff, EBelowProtectedMinimum);
    let sell_amount = balance.value();
    let receipt = SettlementReceipt<Sell, Buy> {
        intent_id: id,
        owner,
        solver: auth.solver,
        pair,
        gross_payout,
        protected_min,
        m_eff,
        sell_amount,
    };
    (coin::from_balance(balance, ctx), receipt)
}

public fun take_authorized_intent_partial<Sell, Buy>(
    state: &mut AuctionState,
    auth: &mut SolutionAuth<Sell, Buy>,
    intent: &mut Intent<Sell, Buy>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Sell>, SettlementReceipt<Sell, Buy>) {
    let (expected_id, fill, gross_payout, protected_min) = next_authorized(auth);
    let id = intent.intent_id();
    assert!(id == expected_id, EIntentMismatch);
    assert!(intent.target_epoch() == auth.epoch, EWrongEpoch);
    assert!(!intent.is_expired(clock), EIntentExpired);
    assert!(fill > 0, EZeroFill);
    auction::assert_not_partial_filled_this_epoch(state, &id);

    let pair = types::pair_key<Sell, Buy>();
    let (owner, balance, m_eff) = intent_book::consume_intent_partial(intent, fill);
    assert!(protected_min >= m_eff, EBelowProtectedMinimum);
    auction::mark_partial_filled(state, id);
    let sell_amount = balance.value();
    let receipt = SettlementReceipt<Sell, Buy> {
        intent_id: id,
        owner,
        solver: auth.solver,
        pair,
        gross_payout,
        protected_min,
        m_eff,
        sell_amount,
    };
    (coin::from_balance(balance, ctx), receipt)
}

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
    let protected_min = receipt.protected_min;
    finalize_settlement(
        state,
        registry,
        config,
        fee_vault,
        receipt,
        payout,
        gross - protected_min,
        protected_min,
        ctx,
    );
}

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
    let protected_min = receipt.protected_min;
    let mid = price_adapter::read_mid_price(num_pool, config, clock);
    let (score_value, _) = normalize_surplus<Buy, NumBase, NumQuote>(
        config,
        gross - protected_min,
        protected_min,
        mid,
    );

    finalize_settlement(
        state,
        registry,
        config,
        fee_vault,
        receipt,
        payout,
        score_value,
        protected_min,
        ctx,
    );
}

fun finalize_settlement<Sell, Buy, Stake>(
    state: &mut AuctionState,
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    fee_vault: &mut FeeVault<Buy>,
    receipt: SettlementReceipt<Sell, Buy>,
    mut payout: Coin<Buy>,
    score_value: u64,
    _floor_value: u64,
    ctx: &mut TxContext,
) {
    let SettlementReceipt {
        intent_id,
        owner,
        solver,
        pair,
        gross_payout,
        protected_min,
        m_eff: _,
        sell_amount,
    } = receipt;
    assert!(payout.value() == gross_payout, EBadGrossPayout);
    assert!(solver_registry::is_active(registry, config, solver), ESolverNotActive);

    let gross = payout.value();
    let (volume_fee, surplus_fee, total_fee) = compute_fees(config, &pair, gross, protected_min);
    let solver_fee = math::mul_div_floor(total_fee, config.solver_fee_share_ppm(), math::ppm_denom());
    let protocol_fee = total_fee - solver_fee;
    let net = gross - total_fee;
    let epoch = auction::current_epoch(state);

    if (total_fee > 0) {
        let mut fee_coin = payout.split(total_fee, ctx);
        if (solver_fee > 0) {
            if (protocol_fee == 0) {
                transfer::public_transfer(fee_coin, solver);
            } else {
                let solver_coin = fee_coin.split(solver_fee, ctx);
                transfer::public_transfer(solver_coin, solver);
                fee_vault::deposit_fee(fee_vault, fee_coin, epoch);
            };
            events::emit_solver_fee_paid(epoch, solver, solver_fee, type_name::with_defining_ids<Buy>());
        } else {
            fee_vault::deposit_fee(fee_vault, fee_coin, epoch);
        };
    };

    auction::record_settlement(state, volume_fee, surplus_fee, protocol_fee, solver_fee);
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
    events::emit_batch_fee_summary(epoch, volume_fee, surplus_fee, protocol_fee, 1);

    transfer::public_transfer(payout, owner);
}

fun next_authorized<Sell, Buy>(
    auth: &mut SolutionAuth<Sell, Buy>,
): (ID, u64, u64, u64) {
    let i = auth.next;
    assert!(i < auth.intent_ids.length(), EAuthExhausted);
    auth.next = i + 1;
    (auth.intent_ids[i], auth.fills[i], auth.gross_payouts[i], auth.protected_mins[i])
}

fun assert_solution_vectors(
    intent_ids: &vector<ID>,
    fills: &vector<u64>,
    gross_payouts: &vector<u64>,
    protected_mins: &vector<u64>,
) {
    let n = intent_ids.length();
    assert!(n > 0, EEmptySolution);
    assert!(fills.length() == n && gross_payouts.length() == n && protected_mins.length() == n, ELengthMismatch);
    let mut i = 0;
    while (i < n) {
        assert!(fills[i] > 0, EZeroFill);
        assert!(gross_payouts[i] >= protected_mins[i], EBelowProtectedMinimum);
        i = i + 1;
    }
}

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

fun normalize_surplus<Buy, NumBase, NumQuote>(
    config: &GlobalConfig,
    surplus: u64,
    floor: u64,
    mid: u64,
): (u64, u64) {
    let buy_t = type_name::with_defining_ids<Buy>();
    let base_t = type_name::with_defining_ids<NumBase>();
    let quote_t = type_name::with_defining_ids<NumQuote>();
    let num_t = config.numeraire_type();

    if (buy_t == num_t) {
        (surplus, floor)
    } else if (buy_t == base_t && quote_t == num_t) {
        (
            price_adapter::normalize_base_to_quote(surplus, mid),
            price_adapter::normalize_base_to_quote(floor, mid),
        )
    } else if (buy_t == quote_t && base_t == num_t) {
        (
            price_adapter::normalize_quote_to_base(surplus, mid),
            price_adapter::normalize_quote_to_base(floor, mid),
        )
    } else {
        assert!(false, EBadNumerairePool);
        (0, 0)
    }
}

fun assert_solver_registry<Stake>(config: &GlobalConfig, registry: &SolverRegistry<Stake>) {
    config.assert_solver_registry_id(solver_registry::id(registry));
}

#[test_only]
public fun authorize_for_testing<Sell, Buy>(
    state: &AuctionState,
    solution_id: vector<u8>,
    solver: address,
    intent_ids: vector<ID>,
    fills: vector<u64>,
    gross_payouts: vector<u64>,
    protected_mins: vector<u64>,
): SolutionAuth<Sell, Buy> {
    assert_solution_vectors(&intent_ids, &fills, &gross_payouts, &protected_mins);
    SolutionAuth<Sell, Buy> {
        solution_id,
        solver,
        epoch: auction::current_epoch(state),
        intent_ids,
        fills,
        gross_payouts,
        protected_mins,
        next: 0,
    }
}
