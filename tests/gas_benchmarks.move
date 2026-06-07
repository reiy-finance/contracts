#[test_only]
module reiy::gas_benchmarks;

use reiy::auction::{Self, AuctionState};
use reiy::config::GlobalConfig;
use reiy::fee_vault::FeeVault;
use reiy::intent_book::Intent;
use reiy::settlement;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::test_helpers::{Self as h, TOKA, USDC};
use sui::clock::Clock;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const USER: address = @0x1;
const SOLVER: address = @0x5;
const MID: u64 = 2_000_000_000;
const DEADLINE: u64 = 10_000_000;

fun register_solver(sc: &mut Scenario) {
    ts::next_tx(sc, SOLVER);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(2_000_000_000, ts::ctx(sc)), b"http://solver", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
}

fun submit_one(sc: &mut Scenario, clock: &Clock, sell: u64, min_out: u64): ID {
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
        &mut state,
        &cfg,
        h::mint<TOKA>(sell, ts::ctx(sc)),
        min_out,
        MID,
        500,
        true,
        false,
        DEADLINE,
        clock,
        ts::ctx(sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    id
}

fun settle_one(
    sc: &mut Scenario,
    clock: &Clock,
    state: &mut AuctionState,
    registry: &mut SolverRegistry<SUI>,
    cfg: &GlobalConfig,
    vault: &mut FeeVault<USDC>,
    id: ID,
    sell: u64,
    gross: u64,
    protected_min: u64,
) {
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, USDC>(
        state,
        b"bench",
        SOLVER,
        vector[id],
        vector[sell],
        vector[gross],
        vector[protected_min],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_full(state, &mut auth, intent, clock, ts::ctx(sc));
    h::burn(sell_coin);
    settlement::settle_intent_numeraire(
        state,
        registry,
        cfg,
        vault,
        receipt,
        h::mint<USDC>(gross, ts::ctx(sc)),
        ts::ctx(sc),
    );
}

#[test]
fun bench_submit_100_intents_only() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);

    let mut i = 0;
    while (i < 100) {
        ts::next_tx(&mut sc, USER);
        submit_one(&mut sc, &clock, 1_000 + i, 1_900 + i * 2);
        i = i + 1;
    };

    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun bench_settle_solution_batch_size_four() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc);

    ts::next_tx(&mut sc, USER);
    let id1 = submit_one(&mut sc, &clock, 1_000, 1_900);
    ts::next_tx(&mut sc, USER);
    let id2 = submit_one(&mut sc, &clock, 1_001, 1_902);
    ts::next_tx(&mut sc, USER);
    let id3 = submit_one(&mut sc, &clock, 1_002, 1_904);
    ts::next_tx(&mut sc, USER);
    let id4 = submit_one(&mut sc, &clock, 1_003, 1_906);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);

    settle_one(&mut sc, &clock, &mut state, &mut registry, &cfg, &mut vault, id1, 1_000, 2_000, 1_900);
    settle_one(&mut sc, &clock, &mut state, &mut registry, &cfg, &mut vault, id2, 1_001, 2_002, 1_902);
    settle_one(&mut sc, &clock, &mut state, &mut registry, &cfg, &mut vault, id3, 1_002, 2_004, 1_904);
    settle_one(&mut sc, &clock, &mut state, &mut registry, &cfg, &mut vault, id4, 1_003, 2_006, 1_906);

    assert!(auction::settled_intent_count(&state) == 4, 0);
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);

    clock.destroy_for_testing();
    ts::end(sc);
}
