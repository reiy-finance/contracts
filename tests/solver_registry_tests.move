#[test_only]
module reiy::solver_registry_tests;

use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use reiy::config::GlobalConfig;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::test_helpers::{Self as h};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;

fun stake_amt(): u64 { 2_000_000_000 } // 2 SUI

#[test]
fun test_register_and_query() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"http://s", ts::ctx(&mut sc));
        assert!(reg::is_registered(&registry, SOLVER), 0);
        assert!(reg::is_active(&registry, &cfg, SOLVER), 1);
        assert!(reg::stake_of(&registry, SOLVER) == stake_amt(), 2);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::ESolverAlreadyRegistered)]
fun test_duplicate_register_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EStakeTooSmall)]
fun test_stake_too_small_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(1, ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
fun test_top_up_and_slash_suspends() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        reg::top_up_stake(&mut registry, h::mint<SUI>(1_000_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc));
        assert!(reg::stake_of(&registry, SOLVER) == stake_amt() + 1_000_000_000, 0);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    // slash 3 reserved obligations -> suspended
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let k1 = reg::bid_reservation_key(0, 1);
        let k2 = reg::bid_reservation_key(0, 2);
        let k3 = reg::bid_reservation_key(0, 3);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k1, 100);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k2, 100);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k3, 100);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 300, 4);
        let b1 = reg::slash_reserved_stake(&mut registry, k1, reg::reason_timeout(), ts::ctx(&mut sc));
        let b2 = reg::slash_reserved_stake(&mut registry, k2, reg::reason_timeout(), ts::ctx(&mut sc));
        assert!(reg::is_active(&registry, &cfg, SOLVER), 1); // still active after 2
        let b3 = reg::slash_reserved_stake(&mut registry, k3, reg::reason_timeout(), ts::ctx(&mut sc));
        assert!(!reg::is_active(&registry, &cfg, SOLVER), 2); // suspended after 3
        assert!(reg::slash_count(&registry, SOLVER) == 3, 3);
        sui::balance::destroy_for_testing(b1);
        sui::balance::destroy_for_testing(b2);
        sui::balance::destroy_for_testing(b3);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
fun test_deregister_reregister_preserves_slash_history() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let k1 = reg::bid_reservation_key(0, 1);
        let k2 = reg::bid_reservation_key(0, 2);
        let k3 = reg::bid_reservation_key(0, 3);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k1, 100);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k2, 100);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, k3, 100);
        sui::balance::destroy_for_testing(reg::slash_reserved_stake(&mut registry, k1, reg::reason_timeout(), ts::ctx(&mut sc)));
        sui::balance::destroy_for_testing(reg::slash_reserved_stake(&mut registry, k2, reg::reason_timeout(), ts::ctx(&mut sc)));
        sui::balance::destroy_for_testing(reg::slash_reserved_stake(&mut registry, k3, reg::reason_timeout(), ts::ctx(&mut sc)));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let stake = reg::deregister_solver(&mut registry, ts::ctx(&mut sc));
        reg::register_solver(&mut registry, &cfg, stake, b"u", ts::ctx(&mut sc));
        assert!(reg::slash_count(&registry, SOLVER) == 3, 0);
        assert!(!reg::is_active(&registry, &cfg, SOLVER), 1);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
fun test_reserve_release_and_deregister() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        let key = reg::bid_reservation_key(0, 1);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, key, 500);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 500, 0);
        assert!(reg::available_stake_of(&registry, SOLVER) == stake_amt() - 500, 1);
        reg::release_stake(&mut registry, key);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 2);
        let stake = reg::deregister_solver(&mut registry, ts::ctx(&mut sc));
        assert!(stake.value() == stake_amt(), 3);
        h::burn(stake);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EReservationExists)]
fun test_duplicate_reservation_key_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        let key = reg::bid_reservation_key(0, 1);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, key, 100);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, key, 100);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EInsufficientStake)]
fun test_reserve_over_available_stake_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::reserve_stake(&mut registry, &cfg, SOLVER, reg::bid_reservation_key(0, 1), stake_amt() + 1);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}
