// Copyright (c) Reiy Finance

/// Protocol fee and slash treasury.
module reiy::treasury;

use reiy::config::{Self, GlobalConfig, AdminCap};
use reiy::events;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};

#[error]
const EInsufficient: vector<u8> = b"treasury balance insufficient";
#[error]
const ENumeraireMismatch: vector<u8> = b"N does not match configured numeraire";

/// Treasury for numeraire revenue and slashed stake.
public struct ProtocolTreasury<phantom N, phantom Stake> has key {
    id: UID,
    balance: Balance<N>,
    stake_balance: Balance<Stake>,
    total_collected: u64,
    total_stake_slashed: u64,
    total_fallback_bounty_paid: u64,
}

public fun init_treasury<N, Stake>(config: &GlobalConfig, _cap: &AdminCap, ctx: &mut TxContext): ID {
    assert!(
        std::type_name::with_defining_ids<N>() == config::numeraire_type(config),
        ENumeraireMismatch,
    );
    let treasury = ProtocolTreasury<N, Stake> {
        id: object::new(ctx),
        balance: balance::zero<N>(),
        stake_balance: balance::zero<Stake>(),
        total_collected: 0,
        total_stake_slashed: 0,
        total_fallback_bounty_paid: 0,
    };
    let id = object::id(&treasury);
    transfer::share_object(treasury);
    id
}

public(package) fun deposit_fee<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    fee: Coin<N>,
    epoch: u64,
) {
    let amount = fee.value();
    treasury.balance.join(fee.into_balance());
    treasury.total_collected = treasury.total_collected + amount;
    events::emit_protocol_fee_collected(epoch, amount);
}

public(package) fun deposit_slashed_stake<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    stake: Coin<Stake>,
    gross_amount: u64,
    epoch: u64,
) {
    let amount = stake.value();
    treasury.stake_balance.join(stake.into_balance());
    treasury.total_stake_slashed = treasury.total_stake_slashed + gross_amount;
    events::emit_stake_slash_deposited(epoch, amount);
}

public(package) fun record_fallback_bounty<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    amount: u64,
) {
    treasury.total_fallback_bounty_paid = treasury.total_fallback_bounty_paid + amount;
}

public(package) fun withdraw_reward<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<N> {
    assert!(amount <= treasury.balance.value(), EInsufficient);
    coin::take(&mut treasury.balance, amount, ctx)
}

public fun withdraw_protocol_fees<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    amount: u64,
    _cap: &AdminCap,
    ctx: &mut TxContext,
): Coin<N> {
    assert!(amount <= treasury.balance.value(), EInsufficient);
    events::emit_protocol_fee_withdrawn(ctx.sender(), amount);
    coin::take(&mut treasury.balance, amount, ctx)
}

public fun withdraw_slashed_stake<N, Stake>(
    treasury: &mut ProtocolTreasury<N, Stake>,
    amount: u64,
    _cap: &AdminCap,
    ctx: &mut TxContext,
): Coin<Stake> {
    assert!(amount <= treasury.stake_balance.value(), EInsufficient);
    events::emit_slashed_stake_withdrawn(ctx.sender(), amount);
    coin::take(&mut treasury.stake_balance, amount, ctx)
}

public fun id<N, Stake>(t: &ProtocolTreasury<N, Stake>): ID { object::id(t) }

public fun balance<N, Stake>(t: &ProtocolTreasury<N, Stake>): u64 { t.balance.value() }

public fun stake_balance<N, Stake>(t: &ProtocolTreasury<N, Stake>): u64 {
    t.stake_balance.value()
}

public fun total_collected<N, Stake>(t: &ProtocolTreasury<N, Stake>): u64 {
    t.total_collected
}

public fun total_stake_slashed<N, Stake>(t: &ProtocolTreasury<N, Stake>): u64 {
    t.total_stake_slashed
}

public fun total_fallback_bounty_paid<N, Stake>(t: &ProtocolTreasury<N, Stake>): u64 {
    t.total_fallback_bounty_paid
}
