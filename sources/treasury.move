// Copyright (c) Reiy Finance

/// Protocol treasury for numeraire-denominated fees and solver rewards.
module reiy::treasury;

use reiy::config::{Self, GlobalConfig, AdminCap};
use reiy::events;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};

#[error]
const EInsufficient: vector<u8> = b"treasury balance insufficient";
#[error]
const ENumeraireMismatch: vector<u8> = b"N does not match configured numeraire";

/// Shared protocol treasury denominated in numeraire token `N`.
/// * `id`              - UID of the shared object
/// * `balance`         - Current numeraire balance available for rewards
/// * `total_collected` - Cumulative fees deposited since deployment (audit metric)
public struct ProtocolTreasury<phantom N> has key {
    id: UID,
    balance: Balance<N>,
    total_collected: u64,
}

/// Create the shared treasury for numeraire `N`. Asserts `N == config.numeraire_type`.
public fun init_treasury<N>(config: &GlobalConfig, _cap: &AdminCap, ctx: &mut TxContext) {
    assert!(
        std::type_name::with_defining_ids<N>() == config::numeraire_type(config),
        ENumeraireMismatch,
    );
    transfer::share_object(ProtocolTreasury<N> {
        id: object::new(ctx),
        balance: balance::zero<N>(),
        total_collected: 0,
    });
}

public(package) fun deposit_fee<N>(treasury: &mut ProtocolTreasury<N>, fee: Coin<N>, epoch: u64) {
    let amount = fee.value();
    treasury.balance.join(fee.into_balance());
    treasury.total_collected = treasury.total_collected + amount;
    events::emit_protocol_fee_collected(epoch, amount);
}

public(package) fun withdraw_reward<N>(
    treasury: &mut ProtocolTreasury<N>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<N> {
    assert!(amount <= treasury.balance.value(), EInsufficient);
    coin::take(&mut treasury.balance, amount, ctx)
}

public fun balance<N>(t: &ProtocolTreasury<N>): u64 { t.balance.value() }

public fun total_collected<N>(t: &ProtocolTreasury<N>): u64 { t.total_collected }
