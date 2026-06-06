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
use reiy::treasury;

// === Marker coin types ===
public struct USDC has drop {} // protocol numeraire
public struct TOKA has drop {}
public struct TOKB has drop {}

public fun k(): u64 { 1_000_000_000 }

public fun mint<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}

public fun burn<T>(c: Coin<T>) { coin::burn_for_testing(c); }

public fun new_clock(ctx: &mut TxContext): Clock {
    clock::create_for_testing(ctx)
}

/// Initialize canonical test protocol objects including FeeVault<USDC>.
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
        config::set_numeraire<USDC>(&mut cfg, &cap);
        // v1 numeraire-only: every supported pair must buy the numeraire (USDC). A non-numeraire
        // Buy pair such as TOKA/TOKB is now rejected by add_supported_pair (audit F-009-1 gate).
        config::add_supported_pair<TOKA, USDC>(&mut cfg, &cap);
        config::add_supported_pair<TOKB, USDC>(&mut cfg, &cap);
        let registry_id = solver_registry::init_for_testing<SUI>(&cap, ts::ctx(scenario));
        let treasury_id = treasury::init_treasury<USDC, SUI>(&cfg, &cap, ts::ctx(scenario));
        config::set_solver_registry_id(&mut cfg, registry_id, &cap);
        config::set_protocol_treasury_id(&mut cfg, treasury_id, &cap);
        // Create and register the canonical FeeVault<USDC>
        let vault_id = fee_vault::init_fee_vault<USDC>(&cap, ts::ctx(scenario));
        config::register_fee_vault<USDC>(&mut cfg, vault_id, &cap);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(cfg);
    };
}
