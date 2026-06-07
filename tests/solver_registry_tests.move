#[test_only]
module reiy::solver_registry_tests;

use reiy::config::GlobalConfig;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::test_helpers::{Self as h};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;

fun stake_amt(): u64 { 2_000_000_000 }

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
        assert!(reg::available_stake_of(&registry, SOLVER) == stake_amt(), 3);
        assert!(reg::url(&registry, SOLVER) == b"http://s", 4);
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
fun test_top_up_withdraw_and_deregister() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        reg::top_up_stake(&mut registry, h::mint<SUI>(1_000_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc));
        assert!(reg::stake_of(&registry, SOLVER) == stake_amt() + 1_000_000_000, 0);
        let withdrawn = reg::withdraw_available_stake(&mut registry, 500, ts::ctx(&mut sc));
        assert!(withdrawn.value() == 500, 1);
        h::burn(withdrawn);
        assert!(reg::available_stake_of(&registry, SOLVER) == stake_amt() + 1_000_000_000 - 500, 2);
        let stake = reg::deregister_solver(&mut registry, ts::ctx(&mut sc));
        assert!(stake.value() == stake_amt() + 1_000_000_000 - 500, 3);
        h::burn(stake);
        assert!(!reg::is_registered(&registry, SOLVER), 4);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::solver_registry::EInsufficientStake)]
fun test_withdraw_over_stake_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        reg::register_solver(&mut registry, &cfg, h::mint<SUI>(stake_amt(), ts::ctx(&mut sc)), b"u", ts::ctx(&mut sc));
        let c = reg::withdraw_available_stake(&mut registry, stake_amt() + 1, ts::ctx(&mut sc));
        h::burn(c);
        ts::return_shared(cfg);
        ts::return_shared(registry);
    };
    ts::end(sc);
}
