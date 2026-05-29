#[test_only]
module reiy::solver_registry_tests;

use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use reiy::config::GlobalConfig;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::test_helpers::{Self as h};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;

fun bond_amt(): u64 { 2_000_000_000 } // 2 SUI

#[test]
fun test_register_and_query() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(bond_amt(), ts::ctx(&mut sc)), b"http://s", ts::ctx(&mut sc));
        assert!(reg::is_registered(&registry, SOLVER), 0);
        assert!(reg::is_active(&registry, SOLVER), 1);
        assert!(reg::bond_of(&registry, SOLVER) == bond_amt(), 2);
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
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(bond_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(bond_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EBondTooSmall)]
fun test_bond_too_small_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
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
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(bond_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        reg::top_up_bond(&mut registry, h::mint<SUI>(1_000_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc));
        assert!(reg::bond_of(&registry, SOLVER) == bond_amt() + 1_000_000_000, 0);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    // slash 3 times -> suspended
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let b1 = reg::slash(&mut registry, SOLVER, 100, reg::reason_timeout(), ts::ctx(&mut sc));
        let b2 = reg::slash(&mut registry, SOLVER, 100, reg::reason_timeout(), ts::ctx(&mut sc));
        assert!(reg::is_active(&registry, SOLVER), 1); // still active after 2
        let b3 = reg::slash(&mut registry, SOLVER, 100, reg::reason_timeout(), ts::ctx(&mut sc));
        assert!(!reg::is_active(&registry, SOLVER), 2); // suspended after 3
        assert!(reg::slash_count(&registry, SOLVER) == 3, 3);
        sui::balance::destroy_for_testing(b1);
        sui::balance::destroy_for_testing(b2);
        sui::balance::destroy_for_testing(b3);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EInsufficientBond)]
fun test_slash_over_bond_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(bond_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let b = reg::slash(&mut registry, SOLVER, bond_amt() + 1, reg::reason_timeout(), ts::ctx(&mut sc));
        sui::balance::destroy_for_testing(b);
        ts::return_shared(registry);
    };
    ts::end(sc);
}
