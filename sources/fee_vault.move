// Copyright (c) Reiy Finance

/// Per-token protocol fee vault. Settlement deposits the protocol share of Buy-token fees here.
module reiy::fee_vault;

use reiy::config::{GlobalConfig, AdminCap};
use reiy::events;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};

#[error]
const EInsufficient: vector<u8> = b"fee vault balance insufficient";

public struct FeeVault<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    total_collected: u64,
}

/// Create a new FeeVault<T>, register its ID in config, and share it.
/// Returns the vault ID so the caller can pass it to config::register_fee_vault.
public fun init_fee_vault<T>(_cap: &AdminCap, ctx: &mut TxContext): ID {
    let vault = FeeVault<T> {
        id: object::new(ctx),
        balance: balance::zero<T>(),
        total_collected: 0,
    };
    let id = object::id(&vault);
    transfer::share_object(vault);
    id
}

public(package) fun deposit_fee<T>(vault: &mut FeeVault<T>, fee: Coin<T>, epoch: u64) {
    let amount = fee.value();
    vault.balance.join(fee.into_balance());
    vault.total_collected = vault.total_collected + amount;
    events::emit_protocol_fee_collected(epoch, amount);
}

public fun withdraw_fees<T>(
    vault: &mut FeeVault<T>,
    amount: u64,
    _cap: &AdminCap,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(amount <= vault.balance.value(), EInsufficient);
    coin::take(&mut vault.balance, amount, ctx)
}

/// Assert that `vault` is the canonical vault registered in config for token T.
public fun assert_canonical<T>(config: &GlobalConfig, vault: &FeeVault<T>) {
    config.assert_fee_vault_id<T>(object::id(vault));
}

public fun id<T>(vault: &FeeVault<T>): ID { object::id(vault) }

public fun balance<T>(vault: &FeeVault<T>): u64 { vault.balance.value() }

public fun total_collected<T>(vault: &FeeVault<T>): u64 { vault.total_collected }
