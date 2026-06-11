#[test_only]
/// Shared fixtures for REIY stateful tests: marker coin types + a one-shot environment setup.
module reiy::test_helpers;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::{Self, GlobalConfig, AdminCap};
use reiy::auction;
use reiy::fee_vault;
use reiy::solver_registry;

// === Marker coin types ===
public struct USDC has drop {}
public struct TOKA has drop {}
public struct TOKB has drop {}

const COORDINATOR_PUBKEY: vector<u8> =
    x"0101010101010101010101010101010101010101010101010101010101010101";

public fun k(): u64 { 1_000_000_000 }

public fun mint<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

public fun burn<T>(c: Coin<T>) { coin::burn_for_testing(c); }

public fun new_clock(ctx: &mut TxContext): Clock {
    clock::create_for_testing(ctx)
}

/// Initialize canonical test protocol objects and fee vaults used by tests.
public fun setup_all(scenario: &mut Scenario, admin: address) {
    ts::next_tx(scenario, admin);
    {
        let ctx = ts::ctx(scenario);
        config::init_for_testing(ctx);
        auction::init_for_testing(ctx);
    };
    ts::next_tx(scenario, admin);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(scenario);
        let cap = ts::take_from_sender<AdminCap>(scenario);
        let usdc_vault_id = fee_vault::init_fee_vault<USDC>(&cap, ts::ctx(scenario));
        config::register_fee_vault<USDC>(&mut cfg, usdc_vault_id, &cap);
        let tokb_vault_id = fee_vault::init_fee_vault<TOKB>(&cap, ts::ctx(scenario));
        config::register_fee_vault<TOKB>(&mut cfg, tokb_vault_id, &cap);
        config::add_supported_pair<TOKA, USDC>(&mut cfg, &cap);
        config::add_supported_pair<TOKB, USDC>(&mut cfg, &cap);
        let registry_id = solver_registry::init_for_testing<SUI>(&cap, ts::ctx(scenario));
        config::set_solver_registry_id(&mut cfg, registry_id, &cap);
        config::set_execution_coordinator(&mut cfg, COORDINATOR_PUBKEY, 1, &cap);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(cfg);
    };
}
