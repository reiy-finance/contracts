#[test_only]
module reiy::config_tests;

use sui::test_scenario::{Self as ts};
use reiy::config::{Self, GlobalConfig, AdminCap};
use reiy::test_helpers::{Self as h, USDC, TOKA};

const ADMIN: address = @0xAD;
const BOB: address = @0xB0B;

#[test]
fun test_defaults() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    { config::init_for_testing(ts::ctx(&mut sc)); };
    ts::next_tx(&mut sc, ADMIN);
    {
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        assert!(config::version(&cfg) == 5, 0);
        // PPM fee defaults
        assert!(config::standard_volume_fee_ppm(&cfg) == 200, 1);
        assert!(config::correlated_volume_fee_ppm(&cfg) == 30, 2);
        assert!(config::surplus_fee_ppm(&cfg) == 500_000, 3);
        assert!(config::surplus_fee_cap_ppm(&cfg) == 9_800, 4);
        assert!(config::max_total_fee_ppm(&cfg) == 10_000, 5);
        assert!(config::solver_reward_fee_share_ppm(&cfg) == 0, 6);
        // Other defaults unchanged
        assert!(config::max_slippage_tolerance_bps(&cfg) == 500, 7);
        assert!(config::grief_factor_bps(&cfg) == 15_000, 8);
        assert!(config::fallback_bounty_bps(&cfg) == 0, 9);
        assert!(config::max_allocation_bids(&cfg) == 32, 10);
        assert!(config::max_allocation_intents(&cfg) == 128, 11);
        assert!(config::max_allocation_pairs(&cfg) == 16, 12);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
fun test_setters_and_allowlists() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        // PPM fee setters
        config::set_standard_volume_fee_ppm(&mut cfg, 100, &cap);
        assert!(config::standard_volume_fee_ppm(&cfg) == 100, 0);
        config::set_correlated_volume_fee_ppm(&mut cfg, 20, &cap);
        assert!(config::correlated_volume_fee_ppm(&cfg) == 20, 1);
        config::set_surplus_fee_ppm(&mut cfg, 300_000, &cap);
        assert!(config::surplus_fee_ppm(&cfg) == 300_000, 2);
        // Other setters
        config::set_max_slippage(&mut cfg, 300, &cap);
        assert!(config::max_slippage_tolerance_bps(&cfg) == 300, 3);
        config::set_fallback_bounty_bps(&mut cfg, 500, &cap);
        assert!(config::fallback_bounty_bps(&cfg) == 500, 4);
        config::set_max_allocation_bids(&mut cfg, 8, &cap);
        assert!(config::max_allocation_bids(&cfg) == 8, 5);
        config::set_max_allocation_intents(&mut cfg, 16, &cap);
        assert!(config::max_allocation_intents(&cfg) == 16, 6);
        config::set_max_allocation_pairs(&mut cfg, 4, &cap);
        assert!(config::max_allocation_pairs(&cfg) == 4, 7);
        let registry_id = config::solver_registry_id(&cfg);
        let treasury_id = config::protocol_treasury_id(&cfg);
        config::set_solver_registry_id(&mut cfg, registry_id, &cap);
        config::set_protocol_treasury_id(&mut cfg, treasury_id, &cap);
        assert!(config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 8);
        config::remove_supported_pair<TOKA, USDC>(&mut cfg, &cap);
        assert!(!config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 9);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

/// Volume fee PPM above MAX_VOLUME_FEE_PPM (10_000 = 1%) should abort.
#[test]
#[expected_failure(abort_code = reiy::config::EInvalidParam)]
fun test_volume_fee_ppm_over_max_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_standard_volume_fee_ppm(&mut cfg, 10_001, &cap); // > MAX_VOLUME_FEE_PPM
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::EInvalidParam)]
fun test_fallback_bounty_over_max_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_fallback_bounty_bps(&mut cfg, 1_001, &cap); // > 10%
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::EInvalidParam)]
fun test_grief_factor_below_one_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_grief_factor(&mut cfg, 9_999, &cap); // < 1.0x
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
fun test_roles() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        assert!(config::has_role(&cfg, ADMIN, config::role_config_admin()), 0);
        assert!(!config::has_role(&cfg, BOB, config::role_config_admin()), 1);
        config::grant_role(&mut cfg, BOB, config::role_config_admin(), &cap);
        assert!(config::has_role(&cfg, BOB, config::role_config_admin()), 2);
        config::revoke_role(&mut cfg, BOB, config::role_config_admin(), &cap);
        assert!(!config::has_role(&cfg, BOB, config::role_config_admin()), 3);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::ENotAdmin)]
fun test_assert_admin_rejects_non_admin() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        config::assert_config_admin(&cfg, BOB);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

/// Fee vault registered and assert_canonical passes for the canonical vault.
#[test]
fun test_fee_vault_registered_in_config() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let vault = ts::take_shared<reiy::fee_vault::FeeVault<USDC>>(&mut sc);
        reiy::fee_vault::assert_canonical<USDC>(&cfg, &vault);
        ts::return_shared(vault);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

/// Correlated fee tier returns correlated_volume_fee_ppm for a pair.
#[test]
fun test_pair_fee_tier_correlated() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        let pair_key = reiy::types::pair_key<TOKA, USDC>();
        // Default is Standard (200 ppm)
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 200, 0);
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_correlated(), &cap);
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 30, 1);
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_disabled(), &cap);
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 0, 2);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}
