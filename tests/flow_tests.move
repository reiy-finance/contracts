#[test_only]
/// End-to-end auction lifecycle tests: collection -> bid -> benchmark/allocation -> winner ->
/// settlement -> close, plus the key adversarial / abort paths.
module reiy::flow_tests;

use sui::sui::SUI;
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::GlobalConfig;
use reiy::auction::{Self, AuctionState};
use reiy::intent_book::Intent;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::treasury::ProtocolTreasury;
use reiy::settlement;
use reiy::test_helpers::{Self as h, USDC, TOKA};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;
const AUC: address = @0xA0;
const U1: address = @0x1;

const MID: u64 = 2_000_000_000; // 2.0x TOKA->USDC
const DEADLINE: u64 = 10_000_000;
const BOND: u64 = 2_000_000_000;

// === helpers ===

fun register_solver(sc: &mut Scenario, who: address) {
    ts::next_tx(sc, who);
    let mut registry = ts::take_shared<SolverRegistry>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(BOND, ts::ctx(sc)), b"http://s", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
}

fun advance(sc: &mut Scenario, clock: &Clock) {
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    auction::advance_phase(&mut state, &cfg, clock);
    ts::return_shared(cfg);
    ts::return_shared(state);
}

// === full happy path ===

#[test]
fun test_full_lifecycle_happy() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);

    // clock
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);

    // --- collection: two TOKA->USDC intents from U1 ---
    ts::next_tx(&mut sc, U1);
    let id1;
    let id2;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        id1 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        id2 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(500, ts::ctx(&mut sc)),
            950, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };

    register_solver(&mut sc, SOLVER);

    // --- advance to Bid ---
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // --- Bid: reference bid (seq 0) + winning bid (seq 1) ---
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // reference bid: payouts 1.1x of m_eff (1900,950) -> (2090,1045)
        auction::submit_bid(
            &mut state, &registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc),
        );
        // winning bid: payouts 2.2x of m_eff -> (4180,2090); surplus over benchmark floor = 3135
        auction::submit_bid(
            &mut state, &registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[4_180, 2_090], false, 3_135, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    // --- advance to Selection ---
    clock.set_for_testing(7_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // --- Selection: benchmark from bid 0, allocation from bid 1 ---
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &cfg, vector[1], 3_135, 1_000_000_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(state);
    };

    // --- advance to Settlement (winner selected) ---
    clock.set_for_testing(13_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        assert!(auction::is_settlement(&state), 100);
        assert!(!auction::winner_is_fallback(&state), 101);
        ts::return_shared(state);
    };

    // --- settle id1 ---
    settle_one(&mut sc, id1, 4_180, &clock);
    // --- settle id2 ---
    settle_one(&mut sc, id2, 2_090, &clock);

    // --- close ---
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC>>(&mut sc);
        settlement::close_batch(
            &mut state, &cfg, &mut treasury, h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
        );
        assert!(auction::phase_code(&state) == 4, 200); // Close
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };

    // U1 should have received both payouts (4180 + 2090 = 6270 USDC)
    ts::next_tx(&mut sc, U1);
    {
        let c1 = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        let c2 = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(c1.value() + c2.value() == 6_270, 300);
        h::burn(c1);
        h::burn(c2);
    };

    clock.destroy_for_testing();
    ts::end(sc);
}

fun settle_one(sc: &mut Scenario, id: ID, payout: u64, clock: &Clock) {
    ts::next_tx(sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(sc);
    let mut registry = ts::take_shared<SolverRegistry>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(sc, id);
    let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, clock, ts::ctx(sc));
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, receipt, h::mint<USDC>(payout, ts::ctx(sc)),
    );
    h::burn(sell_coin);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
}

/// Drive a standard TOKA->USDC batch (two intents from U1) all the way to the Settlement phase with
/// a reference bid (floors 2090/1045) and a winning bid paying 4180/2090 (committed score 3135).
/// Returns the two intent IDs. The winning solver is `SOLVER`.
fun drive_to_settlement(sc: &mut Scenario, clock: &mut Clock): (ID, ID) {
    clock.set_for_testing(1_000);
    ts::next_tx(sc, U1);
    let id1;
    let id2;
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        id1 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(sc)),
            1_900, MID, 500, true, false, DEADLINE, clock, ts::ctx(sc),
        );
        id2 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(500, ts::ctx(sc)),
            950, MID, 500, true, false, DEADLINE, clock, ts::ctx(sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(sc, SOLVER);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    ts::next_tx(sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let registry = ts::take_shared<SolverRegistry>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(sc));
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[4_180, 2_090], false, 3_135, ts::ctx(sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(7_000);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    ts::next_tx(sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_pair_benchmark(&mut state, vector[0], ts::ctx(sc));
        auction::submit_allocation(&mut state, &cfg, vector[1], 3_135, 1_000_000_000, ts::ctx(sc));
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    (id1, id2)
}

// === SBBO admission ===

#[test]
#[expected_failure(abort_code = reiy::intent_book::EBelowSbboFloor)]
fun test_sbbo_reject_below_floor() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    ts::next_tx(&mut sc, U1);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // floor for 1000 @2x,5% = 1900; min 1899 must be rejected
        let _ = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_899, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::auction::ESlippageTooHigh)]
fun test_sbbo_slippage_above_max_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    ts::next_tx(&mut sc, U1);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let _ = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 501, true, false, DEADLINE, &clock, ts::ctx(&mut sc), // 501 > max 500
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Bid validity ===

#[test]
#[expected_failure(abort_code = reiy::auction::EScopeMismatch)]
fun test_bid_scope_mismatch_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    ts::next_tx(&mut sc, U1);
    let id1;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        id1 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // single pair but declared_multi = true
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[id1], vector[1_000], vector[2_090], true, 190, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::auction::EBondTooSmall)]
fun test_bid_bond_too_small_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    ts::next_tx(&mut sc, U1);
    let id1;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        id1 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER); // bond = 2 SUI
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // huge score -> required bond = score*1.5 >> 2 SUI
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[id1], vector[1_000], vector[2_090], false, 10_000_000_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Settlement aborts ===

#[test]
#[expected_failure(abort_code = reiy::settlement::EBelowFloor)]
fun test_settle_below_floor_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, _id2) = drive_to_settlement(&mut sc, &mut clock);
    // floor for id1 is 2090; pay 2000 (>= min 1900 but < floor) -> EBelowFloor
    settle_one(&mut sc, id1, 2_000, &clock);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EBelowMinimum)]
fun test_settle_below_minimum_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, _id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 100, &clock); // below min 1900
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::auction::EBidEpsrInconsistent)]
fun test_settle_epsr_mismatch_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock);  // ratio 2.0 sets reference
    settle_one(&mut sc, id2, 1_100, &clock);  // ratio ~1.05 -> mismatch
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EScoreMismatch)]
fun test_close_score_mismatch_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    // deliver exactly the floor -> zero surplus -> actual score 0 << committed 3135
    settle_one(&mut sc, id1, 2_090, &clock);
    settle_one(&mut sc, id2, 1_045, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC>>(&mut sc);
        settlement::close_batch(&mut state, &cfg, &mut treasury, h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc));
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Selection fallback ===

#[test]
fun test_selection_fallback_to_benchmark() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    ts::next_tx(&mut sc, U1);
    let id1;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        id1 = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[id1], vector[1_000], vector[2_090], false, 190, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(7_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    // submit ONLY a benchmark, NO allocation
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        auction::submit_pair_benchmark(&mut state, vector[0], ts::ctx(&mut sc));
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        assert!(auction::is_settlement(&state), 0);
        assert!(auction::winner_is_fallback(&state), 1);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Fallback slashing ===

#[test]
fun test_fallback_slash_on_deadline_miss() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (_id1, _id2) = drive_to_settlement(&mut sc, &mut clock);
    // do not settle; jump past the settlement deadline (13_000 + 30_000)
    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        settlement::trigger_fallback(&mut state, &mut registry, &cfg, &clock, ts::ctx(&mut sc));
        assert!(auction::phase_code(&state) == 6, 0); // Failed
        assert!(reg::bond_of(&registry, SOLVER) == 0, 1); // full bond slashed
        assert!(reg::slash_count(&registry, SOLVER) == 1, 2);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Multi-pair bid cannot be a benchmark ===

#[test]
#[expected_failure(abort_code = reiy::auction::EMultiBidInBenchmark)]
fun test_multi_bid_in_benchmark_rejected() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    // two intents in DIFFERENT directed pairs: TOKA->USDC and TOKB->USDC
    ts::next_tx(&mut sc, U1);
    let ida;
    let idb;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        ida = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        idb = auction::submit_intent_with_price_for_testing<reiy::test_helpers::TOKB, USDC>(
            &mut state, &cfg, h::mint<reiy::test_helpers::TOKB>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // multi-pair bid (spans two pairs)
        auction::submit_bid(&mut state, &registry, &cfg,
            vector[ida, idb], vector[1_000, 1_000], vector[2_090, 2_090], true, 380, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(7_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        auction::submit_pair_benchmark(&mut state, vector[0], ts::ctx(&mut sc)); // bid 0 is multi -> reject
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}
