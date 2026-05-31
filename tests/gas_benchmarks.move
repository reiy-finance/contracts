// Copyright (c) Reiy Finance
/// Gas benchmark tests. Run with:
///   sui move test -s --filter bench_
/// or for CSV:
///   sui move test -s csv --filter bench_ > gas_report.csv
///
/// Each test exercises one logical operation in isolation so the statistics
/// output reports gas per operation, not per full lifecycle.
#[test_only]
module reiy::gas_benchmarks;

use sui::sui::SUI;
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::GlobalConfig;
use reiy::auction::{Self, AuctionState};
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::treasury::ProtocolTreasury;
use reiy::settlement;
use reiy::test_helpers::{Self as h, USDC, TOKA};

const ADMIN:  address = @0xAD;
const SOLVER: address = @0x50;
const AUC:    address = @0xA0;
const U1:     address = @0x01;
const U2:     address = @0x02;
const U3:     address = @0x03;

const MID:      u64 = 2_000_000_000;
const DEADLINE: u64 = 10_000_000;
const STAKE_AMOUNT: u64 = 2_000_000_000;

// ─── shared setup helpers ───────────────────────────────────────────────────

fun base_setup(sc: &mut Scenario, clock: &mut Clock) {
    h::setup_all(sc, ADMIN);
    clock.set_for_testing(1_000);
    // register solver and auctioneer stake accounts
    ts::next_tx(sc, SOLVER);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(STAKE_AMOUNT, ts::ctx(sc)), b"http://s", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::next_tx(sc, AUC);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(STAKE_AMOUNT, ts::ctx(sc)), b"http://a", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
}

fun submit_intent_toka(sc: &mut Scenario, who: address, sell: u64, min: u64, clock: &Clock): ID {
    ts::next_tx(sc, who);
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
        &mut state, &cfg, h::mint<TOKA>(sell, ts::ctx(sc)),
        min, MID, 500, true, false, DEADLINE, clock, ts::ctx(sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    id
}

fun advance(sc: &mut Scenario, clock: &Clock) {
    ts::next_tx(sc, ADMIN);
    let mut state = ts::take_shared<AuctionState>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    auction::advance_phase(&mut state, &mut registry, &cfg, clock);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
}

/// Settle the next available TOKA->USDC intent (LIFO order from take_shared).
/// Call in reverse intent-creation order to keep EPSR ratio consistent.
fun settle_next(sc: &mut Scenario, payout: u64, clock: &Clock) {
    ts::next_tx(sc, SOLVER);
    let mut state    = ts::take_shared<AuctionState>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let intent       = ts::take_shared<reiy::intent_book::Intent<TOKA, USDC>>(sc);
    let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, clock, ts::ctx(sc));
    h::burn(sell_coin);
    settlement::settle_intent_with_values_for_testing(
        &mut state, &mut registry, receipt,
        h::mint<USDC>(payout, ts::ctx(sc)), payout, payout,
    );
    ts::return_shared(registry);
    ts::return_shared(state);
}

// ─── Benchmarks ─────────────────────────────────────────────────────────────

/// submit_intent × 1
#[test]
fun bench_submit_intent_1() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// submit_intent × 5 (batch accumulation cost)
#[test]
fun bench_submit_intent_5() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// submit_bid with 1 intent
#[test]
fun bench_submit_bid_1_intent() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);  // -> Bid
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state    = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg          = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg, vector[id], vector[1_000], vector[2_090], false, 190, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// submit_bid with 5 intents (single pair)
#[test]
fun bench_submit_bid_5_intents() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id1 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id2 = submit_intent_toka(&mut sc, U2, 1_000, 1_900, &clock);
    let id3 = submit_intent_toka(&mut sc, U3, 1_000, 1_900, &clock);
    let id4 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id5 = submit_intent_toka(&mut sc, U2, 1_000, 1_900, &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2, id3, id4, id5],
            vector[1_000, 1_000, 1_000, 1_000, 1_000],
            vector[2_090, 2_090, 2_090, 2_090, 2_090],
            false, 950, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// submit_pair_benchmark + submit_allocation
#[test]
fun bench_submit_benchmark_and_allocation() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id1 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id2 = submit_intent_toka(&mut sc, U2, 500,   950,   &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);  // Bid
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        // seq 0: benchmark bid
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc));
        // seq 1: winning bid
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[4_180, 2_090], false, 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(8_000);
    advance(&mut sc, &clock);  // AllocationSelection
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// take_intent_full + settle_intent (single)
#[test]
fun bench_settle_intent_full_1() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id1 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id2 = submit_intent_toka(&mut sc, U2, 500, 950, &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[4_180, 2_090], false, 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(8_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(14_000);
    advance(&mut sc, &clock);  // Settlement
    settle_next(&mut sc, 2_090, &clock); // id2 (LIFO); benchmarks settle_intent gas, not close
    clock.destroy_for_testing();
    ts::end(sc);
}

/// close_batch after settling 2 intents
#[test]
fun bench_close_batch_2_intents() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id1 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id2 = submit_intent_toka(&mut sc, U2, 500, 950, &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[4_180, 2_090], false, 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(8_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(14_000);
    advance(&mut sc, &clock);
    // settle in reverse creation order (LIFO) so EPSR ratio stays uniform
    settle_next(&mut sc, 2_090, &clock); // id2 (last created)
    settle_next(&mut sc, 4_180, &clock); // id1
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state    = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg          = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(&mut state, &cfg, &mut registry, &mut treasury, h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc));
        ts::return_shared(treasury);
        ts::return_shared(registry);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Full epoch end-to-end: 5 intents, 5 settles, close
#[test]
fun bench_full_epoch_5_intents() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    let id1 = submit_intent_toka(&mut sc, U1, 1_000, 1_900, &clock);
    let id2 = submit_intent_toka(&mut sc, U2, 800,  1_520, &clock);
    let id3 = submit_intent_toka(&mut sc, U3, 600,  1_140, &clock);
    let id4 = submit_intent_toka(&mut sc, U1, 400,   760,  &clock);
    let id5 = submit_intent_toka(&mut sc, U2, 200,   380,  &clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        // benchmark bid (seq 0)
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1,id2,id3,id4,id5],
            vector[1_000,800,600,400,200],
            vector[2_090,1_672,1_254,836,418],
            false, 2_755, ts::ctx(&mut sc));
        // winning bid (seq 1) — 1.5x the benchmark payouts
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1,id2,id3,id4,id5],
            vector[1_000,800,600,400,200],
            vector[2_850,2_280,1_710,1_140,570],
            false, 5_795, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(8_000);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg       = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 5_795, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(14_000);
    advance(&mut sc, &clock);
    // settle in reverse creation order (LIFO) — id5 → id4 → id3 → id2 → id1
    settle_next(&mut sc, 570,   &clock); // id5
    settle_next(&mut sc, 1_140, &clock); // id4
    settle_next(&mut sc, 1_710, &clock); // id3
    settle_next(&mut sc, 2_280, &clock); // id2
    settle_next(&mut sc, 2_850, &clock); // id1
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state    = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg          = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(&mut state, &cfg, &mut registry, &mut treasury, h::mint<USDC>(500, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc));
        ts::return_shared(treasury);
        ts::return_shared(registry);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// advance_phase permissionless call
#[test]
fun bench_advance_phase() {
    let mut sc = ts::begin(ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    base_setup(&mut sc, &mut clock);
    clock.set_for_testing(2_000);
    advance(&mut sc, &clock);  // Collection -> Bid
    clock.destroy_for_testing();
    ts::end(sc);
}

/// register_solver
#[test]
fun bench_register_solver() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, U1);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(STAKE_AMOUNT, ts::ctx(&mut sc)), b"http://solver-a", ts::ctx(&mut sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
    clock.destroy_for_testing();
    ts::end(sc);
}
