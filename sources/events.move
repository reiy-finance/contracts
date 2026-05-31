// Copyright (c) Reiy Finance

/// Canonical event types. Emit functions are package-internal.
module reiy::events;

use reiy::types::PairKey;
use std::type_name::TypeName;
use sui::event;

// settlement_type tags
const SETTLE_COW: u8 = 0;
const SETTLE_DEEPBOOK: u8 = 1;
const SETTLE_AMM: u8 = 2;

public fun settle_cow(): u8 { SETTLE_COW }

public fun settle_deepbook(): u8 { SETTLE_DEEPBOOK }

public fun settle_amm(): u8 { SETTLE_AMM }

// === Event structs ===

public struct IntentCreatedEvent has copy, drop {
    intent_id: ID,
    owner: address,
    sell_type: TypeName,
    buy_type: TypeName,
    sell_amount: u64,
    min_amount_out: u64,
    original_min_amount_out: u64,
    sbbo_floor: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    target_epoch: u64,
    deadline: u64,
    submit_timestamp_ms: u64,
}

public struct IntentCancelledEvent has copy, drop {
    intent_id: ID,
    owner: address,
    returned_amount: u64,
    reason: u8, // 0=manual, 1=expired, 2=partial-fill-complete
}

public struct IntentUpdatedEvent has copy, drop {
    intent_id: ID,
    owner: address,
    new_min_amount_out: u64,
    new_sbbo_floor: u64,
    new_deadline: u64,
    target_epoch: u64,
}

public struct EpochAdvancedEvent has copy, drop {
    epoch: u64,
    phase: u8,
    timestamp_ms: u64,
}

public struct BidSubmittedEvent has copy, drop {
    bid_seq: u64,
    solver: address,
    epoch: u64,
    scope_is_multi: bool,
    score: u64,
    bond_locked: u64,
    intent_count: u64,
}

public struct PairBenchmarkSubmittedEvent has copy, drop {
    auctioneer: address,
    epoch: u64,
    pair: PairKey,
    total_score: u64,
    bid_count: u64,
}

public struct AllocationSubmittedEvent has copy, drop {
    allocation_idx: u64,
    auctioneer: address,
    epoch: u64,
    total_score: u64,
    bond_locked: u64,
    bid_count: u64,
}

public struct WinnerSelectedEvent has copy, drop {
    epoch: u64,
    committed_total_score: u64,
    winner_intent_count: u64,
    fallback: bool,
}

public struct SettlementEvent has copy, drop {
    intent_id: ID,
    solver: address,
    epoch: u64,
    sell_amount: u64,
    buy_amount: u64,
    raw_surplus: u64,
    score_value: u64,
    settlement_type: u8,
}

public struct SettlementCompleteEventV3 has copy, drop {
    epoch: u64,
    actual_score_surplus: u64,
    committed_score: u64,
    settled_intent_count: u64,
    settled_score_value_sum: u64,
}

public struct ProtocolFeeCollectedEvent has copy, drop {
    epoch: u64,
    amount: u64,
}

public struct SolverRegisteredEvent has copy, drop {
    solver: address,
    bond_amount: u64,
}

public struct SolverDeregisteredEvent has copy, drop {
    solver: address,
    returned_bond: u64,
}

public struct SolverSlashedEvent has copy, drop {
    solver: address,
    amount_slashed: u64,
    reason: u8, // 0=timeout, 1=invalid proof, 2=repeated
}

public struct FallbackTriggeredEvent has copy, drop {
    epoch: u64,
    requeued_intent_count: u64,
}

public struct ConfigUpdatedEvent has copy, drop {
    key: vector<u8>,
    old_value: u64,
    new_value: u64,
}

public struct RoleGrantedEvent has copy, drop { member: address, role: u64 }
public struct RoleRevokedEvent has copy, drop { member: address, role: u64 }

// === Emit functions ===

public(package) fun emit_intent_created(
    intent_id: ID,
    owner: address,
    sell_type: TypeName,
    buy_type: TypeName,
    sell_amount: u64,
    min_amount_out: u64,
    original_min_amount_out: u64,
    sbbo_floor: u64,
    sbbo_mid_price: u64,
    slippage_tolerance_bps: u64,
    partial_fillable: bool,
    target_epoch: u64,
    deadline: u64,
    submit_timestamp_ms: u64,
) {
    event::emit(IntentCreatedEvent {
        intent_id,
        owner,
        sell_type,
        buy_type,
        sell_amount,
        min_amount_out,
        original_min_amount_out,
        sbbo_floor,
        sbbo_mid_price,
        slippage_tolerance_bps,
        partial_fillable,
        target_epoch,
        deadline,
        submit_timestamp_ms,
    });
}

public(package) fun emit_intent_cancelled(
    intent_id: ID,
    owner: address,
    returned_amount: u64,
    reason: u8,
) {
    event::emit(IntentCancelledEvent { intent_id, owner, returned_amount, reason });
}

public(package) fun emit_intent_updated(
    intent_id: ID,
    owner: address,
    new_min_amount_out: u64,
    new_sbbo_floor: u64,
    new_deadline: u64,
    target_epoch: u64,
) {
    event::emit(IntentUpdatedEvent {
        intent_id,
        owner,
        new_min_amount_out,
        new_sbbo_floor,
        new_deadline,
        target_epoch,
    });
}

public(package) fun emit_epoch_advanced(epoch: u64, phase: u8, timestamp_ms: u64) {
    event::emit(EpochAdvancedEvent { epoch, phase, timestamp_ms });
}

public(package) fun emit_bid_submitted(
    bid_seq: u64,
    solver: address,
    epoch: u64,
    scope_is_multi: bool,
    score: u64,
    bond_locked: u64,
    intent_count: u64,
) {
    event::emit(BidSubmittedEvent {
        bid_seq,
        solver,
        epoch,
        scope_is_multi,
        score,
        bond_locked,
        intent_count,
    });
}

public(package) fun emit_pair_benchmark_submitted(
    auctioneer: address,
    epoch: u64,
    pair: PairKey,
    total_score: u64,
    bid_count: u64,
) {
    event::emit(PairBenchmarkSubmittedEvent { auctioneer, epoch, pair, total_score, bid_count });
}

public(package) fun emit_allocation_submitted(
    allocation_idx: u64,
    auctioneer: address,
    epoch: u64,
    total_score: u64,
    bond_locked: u64,
    bid_count: u64,
) {
    event::emit(AllocationSubmittedEvent {
        allocation_idx,
        auctioneer,
        epoch,
        total_score,
        bond_locked,
        bid_count,
    });
}

public(package) fun emit_winner_selected(
    epoch: u64,
    committed_total_score: u64,
    winner_intent_count: u64,
    fallback: bool,
) {
    event::emit(WinnerSelectedEvent {
        epoch,
        committed_total_score,
        winner_intent_count,
        fallback,
    });
}

public(package) fun emit_settlement(
    intent_id: ID,
    solver: address,
    epoch: u64,
    sell_amount: u64,
    buy_amount: u64,
    raw_surplus: u64,
    score_value: u64,
    settlement_type: u8,
) {
    event::emit(SettlementEvent {
        intent_id,
        solver,
        epoch,
        sell_amount,
        buy_amount,
        raw_surplus,
        score_value,
        settlement_type,
    });
}

public(package) fun emit_settlement_complete(
    epoch: u64,
    actual_score_surplus: u64,
    committed_score: u64,
    settled_intent_count: u64,
    settled_score_value_sum: u64,
) {
    event::emit(SettlementCompleteEventV3 {
        epoch,
        actual_score_surplus,
        committed_score,
        settled_intent_count,
        settled_score_value_sum,
    });
}

public(package) fun emit_protocol_fee_collected(epoch: u64, amount: u64) {
    event::emit(ProtocolFeeCollectedEvent { epoch, amount });
}

public(package) fun emit_solver_registered(solver: address, bond_amount: u64) {
    event::emit(SolverRegisteredEvent { solver, bond_amount });
}

public(package) fun emit_solver_deregistered(solver: address, returned_bond: u64) {
    event::emit(SolverDeregisteredEvent { solver, returned_bond });
}

public(package) fun emit_solver_slashed(solver: address, amount_slashed: u64, reason: u8) {
    event::emit(SolverSlashedEvent { solver, amount_slashed, reason });
}

public(package) fun emit_fallback_triggered(epoch: u64, requeued_intent_count: u64) {
    event::emit(FallbackTriggeredEvent { epoch, requeued_intent_count });
}

public(package) fun emit_config_updated(key: vector<u8>, old_value: u64, new_value: u64) {
    event::emit(ConfigUpdatedEvent { key, old_value, new_value });
}

public(package) fun emit_role_granted(member: address, role: u64) {
    event::emit(RoleGrantedEvent { member, role });
}

public(package) fun emit_role_revoked(member: address, role: u64) {
    event::emit(RoleRevokedEvent { member, role });
}
