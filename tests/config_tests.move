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
        assert!(config::version(&cfg) == 2, 0);
        assert!(config::protocol_fee_bps(&cfg) == 5, 1);
        assert!(config::max_slippage_tolerance_bps(&cfg) == 500, 3);
        assert!(config::grief_factor_bps(&cfg) == 15_000, 4);
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
        config::set_protocol_fee(&mut cfg, 30, &cap);
        assert!(config::protocol_fee_bps(&cfg) == 30, 0);
        config::set_max_slippage(&mut cfg, 300, &cap);
        assert!(config::max_slippage_tolerance_bps(&cfg) == 300, 1);
        // pair allowlist from setup
        assert!(config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 2);
        config::remove_supported_pair<TOKA, USDC>(&mut cfg, &cap);
        assert!(!config::is_pair_supported(&cfg, &reiy::types::pair_key<TOKA, USDC>()), 3);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::EInvalidParam)]
fun test_fee_over_max_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_protocol_fee(&mut cfg, 1_001, &cap); // > 10%
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
