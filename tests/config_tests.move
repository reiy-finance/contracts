#[test_only]
module reiy::config_tests;

use sui::test_scenario::{Self as ts};
use reiy::config::{Self, GlobalConfig, AdminCap};
use reiy::test_helpers::{Self as h, USDC, TOKA, TOKB};

const ADMIN: address = @0xAD;
const BOB: address = @0xB0B;
const COORDINATOR_PUBKEY_2: vector<u8> =
    x"0101010101010101010101010101010101010101010101010101010101010101";

public struct TOKC has drop {}

#[test]
fun test_defaults() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    { config::init_for_testing(ts::ctx(&mut sc)); };
    ts::next_tx(&mut sc, ADMIN);
    {
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        assert!(config::version(&cfg) == 8, 0);
        // PPM fee defaults
        assert!(config::standard_volume_fee_ppm(&cfg) == 75, 1);
        assert!(config::correlated_volume_fee_ppm(&cfg) == 10, 2);
        assert!(config::surplus_fee_ppm(&cfg) == 100_000, 3);
        assert!(config::surplus_fee_cap_ppm(&cfg) == 1_000, 4);
        assert!(config::max_total_fee_ppm(&cfg) == 1_500, 5);
        assert!(config::solver_fee_share_ppm(&cfg) == 350_000, 6);
        assert!(config::max_slippage_tolerance_bps(&cfg) == 500, 7);
        assert!(config::min_batch_collect_ms(&cfg) == 10_000, 8);
        assert!(config::min_solver_stake(&cfg) == 1_000_000_000, 9);
        assert!(config::execution_coordinator_pubkey(&cfg).length() == 0, 10);
        assert!(config::execution_coordinator_key_version(&cfg) == 0, 11);
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
        config::set_solver_fee_share_ppm(&mut cfg, 600_000, &cap);
        assert!(config::solver_fee_share_ppm(&cfg) == 600_000, 12);
        config::set_min_batch_collect(&mut cfg, 2_000, &cap);
        assert!(config::min_batch_collect_ms(&cfg) == 2_000, 13);
        config::set_min_solver_stake(&mut cfg, 2_000_000_000, &cap);
        assert!(config::min_solver_stake(&cfg) == 2_000_000_000, 14);
        config::set_execution_coordinator(&mut cfg, COORDINATOR_PUBKEY_2, 2, &cap);
        assert!(config::execution_coordinator_key_version(&cfg) == 2, 15);
        config::set_max_slippage(&mut cfg, 300, &cap);
        assert!(config::max_slippage_tolerance_bps(&cfg) == 300, 3);
        let registry_id = config::solver_registry_id(&cfg);
        config::set_solver_registry_id(&mut cfg, registry_id, &cap);
        assert!(config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 8);
        config::remove_supported_pair<TOKA, USDC>(&mut cfg, &cap);
        assert!(!config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 9);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

/// F-005-3: a Custom fee tier above MAX_VOLUME_FEE_PPM must abort (parity with global setters),
/// otherwise volume_fee could exceed gross and brick the pair via u64 underflow.
#[test]
#[expected_failure(abort_code = reiy::config::EInvalidParam)]
fun test_custom_fee_tier_over_max_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_custom(10_001), &cap);
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
#[expected_failure(abort_code = reiy::config::EBadCoordinatorKey)]
fun test_bad_coordinator_key_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_execution_coordinator(&mut cfg, b"short", 2, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
fun test_non_usdc_buy_pair_supported_with_fee_vault() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::add_supported_pair<TOKA, TOKB>(&mut cfg, &cap);
        assert!(config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, TOKB>()), 0);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::EFeeVaultNotRegistered)]
fun test_supported_pair_requires_buy_fee_vault() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::add_supported_pair<TOKA, TOKC>(&mut cfg, &cap);
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
        // Default is Standard (75 ppm)
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 75, 0);
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_correlated(), &cap);
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 10, 1);
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_disabled(), &cap);
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 0, 2);
        // Custom tier within the volume-fee ceiling is accepted
        config::set_pair_fee_tier<TOKA, USDC>(&mut cfg, config::fee_tier_custom(1_000), &cap);
        assert!(config::volume_fee_ppm_for_pair(&cfg, &pair_key) == 1_000, 3);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}
