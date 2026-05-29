// Copyright (c) Reiy Finance

/// Intent lifecycle: SBBO-gated creation, cancellation, update, and full/partial consumption.
/// Sell assets are locked in the shared Intent object until cancel or settlement.
module reiy::intent_book;

use reiy::events;
use reiy::math;
use reiy::types::{Self, PairKey};
use std::type_name;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};

public enum FillStatus has copy, drop, store {
    Open,
    PartialFill,
    Filled,
    Cancelled,
    Expired,
}

const REASON_MANUAL: u8 = 0;

#[error]
const EZeroAmount: vector<u8> = b"sell amount must be > 0";
#[error]
const EZeroMinOut: vector<u8> = b"min_amount_out must be > 0";
#[error]
const EInvalidDeadline: vector<u8> = b"deadline must be in the future";
#[error]
const EBelowSbboFloor: vector<u8> = b"min_amount_out below SBBO floor";
#[error]
const ENotOwner: vector<u8> = b"caller is not the intent owner";
#[error]
const ENotPartialFillable: vector<u8> = b"intent is not partial-fillable";
#[error]
const EFillExceedsRemaining: vector<u8> = b"fill amount exceeds remaining balance";
#[error]
const EZeroFill: vector<u8> = b"fill amount must be > 0";

/// A user trade intent with the sell asset locked on-chain.
/// * `id`                       - UID of the shared object
/// * `owner`                    - Address that submitted the intent
/// * `sell_balance`             - Locked sell tokens; released on cancel or settlement
/// * `min_amount_out`           - Current effective minimum buy amount (may be updated)
/// * `original_min_amount_out`  - Minimum as set at submission; used for partial-fill proportional calc
/// * `original_sell_amount`     - Sell amount at submission; denominator for partial-fill math
/// * `sbbo_floor`               - SBBO admission floor computed at submission
/// * `sbbo_mid_price`           - DeepBook mid-price snapshot used to compute the floor
/// * `slippage_tolerance_bps`   - Slippage tolerance accepted at submission (bps)
/// * `partial_fillable`         - Whether residual volume can roll over to the next epoch
/// * `filled_amount`            - Cumulative sell tokens consumed by partial fills so far
/// * `target_epoch`             - Auction epoch this intent targets for settlement
/// * `deadline`                 - Unix timestamp (ms) after which the intent expires
/// * `submit_timestamp_ms`      - Wall-clock time of submission; used for audit trail
/// * `fill_status`              - Current lifecycle state of the intent
public struct Intent<phantom Sell, phantom Buy> has key {
    id: UID,
    owner: address,
    sell_balance: Balance<Sell>,
    min_amount_out: u64,
    original_min_amount_out: u64,
    original_sell_amount: u64,
    sbbo_floor: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    filled_amount: u64,
    target_epoch: u64,
    deadline: u64,
    submit_timestamp_ms: u64,
    fill_status: FillStatus,
}

public(package) fun create_intent<Sell, Buy>(
    coin: Coin<Sell>,
    min_amount_out: u64,
    sbbo_floor: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    target_epoch: u64,
    deadline: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let sell_amount = coin.value();
    let now = clock.timestamp_ms();
    assert!(sell_amount > 0, EZeroAmount);
    assert!(min_amount_out > 0, EZeroMinOut);
    assert!(deadline > now, EInvalidDeadline);
    assert!(min_amount_out >= sbbo_floor, EBelowSbboFloor);

    let owner = ctx.sender();
    let id = object::new(ctx);
    let intent_id = id.to_inner();
    transfer::share_object(Intent<Sell, Buy> {
        id,
        owner,
        sell_balance: coin.into_balance(),
        min_amount_out,
        original_min_amount_out: min_amount_out,
        original_sell_amount: sell_amount,
        sbbo_floor,
        sbbo_mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        filled_amount: 0,
        target_epoch,
        deadline,
        submit_timestamp_ms: now,
        fill_status: FillStatus::Open,
    });
    events::emit_intent_created(
        intent_id,
        owner,
        type_name::with_defining_ids<Sell>(),
        type_name::with_defining_ids<Buy>(),
        sell_amount,
        min_amount_out,
        min_amount_out,
        sbbo_floor,
        sbbo_mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        target_epoch,
        deadline,
        now,
    );
    intent_id
}

public(package) fun cancel_intent<Sell, Buy>(intent: Intent<Sell, Buy>, ctx: &mut TxContext) {
    assert!(intent.owner == ctx.sender(), ENotOwner);
    let Intent { id, owner, sell_balance, .. } = intent;
    let intent_id = id.to_inner();
    let amount = sell_balance.value();
    transfer::public_transfer(coin::from_balance(sell_balance, ctx), owner);
    object::delete(id);
    events::emit_intent_cancelled(intent_id, owner, amount, REASON_MANUAL);
}

public(package) fun update_intent_params<Sell, Buy>(
    intent: &mut Intent<Sell, Buy>,
    new_min_amount_out: u64,
    new_sbbo_floor: u64,
    new_sbbo_mid_price: u64,
    new_slippage_tolerance_bps: u64,
    new_target_epoch: u64,
    new_deadline: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(intent.owner == ctx.sender(), ENotOwner);
    assert!(new_min_amount_out > 0, EZeroMinOut);
    assert!(new_deadline > clock.timestamp_ms(), EInvalidDeadline);
    assert!(new_min_amount_out >= new_sbbo_floor, EBelowSbboFloor);
    intent.min_amount_out = new_min_amount_out;
    intent.sbbo_floor = new_sbbo_floor;
    intent.sbbo_mid_price = new_sbbo_mid_price;
    intent.slippage_tolerance_bps = new_slippage_tolerance_bps;
    intent.target_epoch = new_target_epoch;
    intent.deadline = new_deadline;
    events::emit_intent_updated(
        intent.id.to_inner(),
        intent.owner,
        new_min_amount_out,
        new_sbbo_floor,
        new_deadline,
        new_target_epoch,
    );
}

/// Consume the full intent; returns `(owner, locked balance, effective min)`.
public(package) fun consume_intent_full<Sell, Buy>(
    intent: Intent<Sell, Buy>,
): (address, Balance<Sell>, u64) {
    let Intent { id, owner, sell_balance, min_amount_out, .. } = intent;
    object::delete(id);
    (owner, sell_balance, min_amount_out)
}

/// Partial consume: returns `(owner, split balance, ceil proportional min)`.
/// Advances `target_epoch` so the residual re-enters the next batch.
public(package) fun consume_intent_partial<Sell, Buy>(
    intent: &mut Intent<Sell, Buy>,
    fill_amount: u64,
): (address, Balance<Sell>, u64) {
    assert!(intent.partial_fillable, ENotPartialFillable);
    assert!(fill_amount > 0, EZeroFill);
    assert!(fill_amount <= intent.sell_balance.value(), EFillExceedsRemaining);
    // m_i(f_i) = ceil(m_i * f / x_i) — uses original sell amount so each partial is comparable
    let m_eff = math::mul_div_ceil(
        intent.original_min_amount_out,
        fill_amount,
        intent.original_sell_amount,
    );
    let split = intent.sell_balance.split(fill_amount);
    intent.filled_amount = intent.filled_amount + fill_amount;
    intent.target_epoch = intent.target_epoch + 1;
    intent.fill_status = if (intent.sell_balance.value() == 0) FillStatus::Filled
    else FillStatus::PartialFill;
    (intent.owner, split, m_eff)
}

// === Getters ===

public fun owner<S, B>(i: &Intent<S, B>): address { i.owner }

public fun remaining_sell<S, B>(i: &Intent<S, B>): u64 { i.sell_balance.value() }

public fun min_amount_out<S, B>(i: &Intent<S, B>): u64 { i.min_amount_out }

public fun original_min_amount_out<S, B>(i: &Intent<S, B>): u64 { i.original_min_amount_out }

public fun original_sell_amount<S, B>(i: &Intent<S, B>): u64 { i.original_sell_amount }

public fun sbbo_floor<S, B>(i: &Intent<S, B>): u64 { i.sbbo_floor }

public fun sbbo_mid_price<S, B>(i: &Intent<S, B>): u64 { i.sbbo_mid_price }

public fun slippage_tolerance_bps<S, B>(i: &Intent<S, B>): u64 { i.slippage_tolerance_bps }

public fun partial_fillable<S, B>(i: &Intent<S, B>): bool { i.partial_fillable }

public fun filled_amount<S, B>(i: &Intent<S, B>): u64 { i.filled_amount }

public fun target_epoch<S, B>(i: &Intent<S, B>): u64 { i.target_epoch }

public fun deadline<S, B>(i: &Intent<S, B>): u64 { i.deadline }

public fun submit_timestamp_ms<S, B>(i: &Intent<S, B>): u64 { i.submit_timestamp_ms }

public fun intent_id<S, B>(i: &Intent<S, B>): ID { i.id.to_inner() }

public fun pair_key<S, B>(_i: &Intent<S, B>): PairKey { types::pair_key<S, B>() }

public fun is_expired<S, B>(i: &Intent<S, B>, clock: &Clock): bool {
    clock.timestamp_ms() > i.deadline
}
