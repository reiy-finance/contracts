#[test_only]
/// End-to-end auction lifecycle tests: collection -> bid -> benchmark/allocation -> winner ->
/// settlement -> close, plus the key adversarial / abort paths.
module reiy::flow_tests;

use sui::sui::SUI;
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::{Self as config, GlobalConfig, AdminCap};
use reiy::auction::{Self, AuctionState};
use reiy::intent_book::{Self, Intent};
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
const STAKE_AMOUNT: u64 = 2_000_000_000;

// === helpers ===

fun register_solver(sc: &mut Scenario, who: address) {
    ts::next_tx(sc, who);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(STAKE_AMOUNT, ts::ctx(sc)), b"http://s", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
}

fun advance(sc: &mut Scenario, clock: &Clock) {
    let mut state = ts::take_shared<AuctionState>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    auction::advance_phase(&mut state, &mut registry, &cfg, clock);
    ts::return_shared(cfg);
    ts::return_shared(registry);
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
    register_solver(&mut sc, AUC);

    // --- advance to Bid ---
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // --- Bid: reference bid (seq 0) + winning bid (seq 1) ---
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // reference bid: payouts 1.1x of m_eff (1900,950) -> (2090,1045)
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc),
        );
        // winning bid: payouts 2.2x of m_eff -> (4180,2090); surplus over benchmark floor = 3135
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 3_135, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    // --- advance to Settlement (winner selected) ---
    clock.set_for_testing(13_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        assert!(auction::is_settlement(&state), 100);
        assert!(!auction::winner_is_fallback(&state), 101);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 1_000_000_000, 102);
        assert!(reg::reserved_stake_of(&registry, AUC) == 0, 103);
        ts::return_shared(registry);
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(
            &mut state, &cfg, &mut registry, &mut treasury,
            h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
        );
        assert!(auction::phase_code(&state) == 4, 200); // Close
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 201);
        ts::return_shared(treasury);
        ts::return_shared(registry);
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
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
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
    register_solver(sc, AUC);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    ts::next_tx(sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 3_135, ts::ctx(sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    (id1, id2)
}

// === Double partial-take of the same intent must revert (F-1 verification) ===
// take_intent_partial does not mark the intent settled, so a solver can take the same intent
// twice before settling. But both receipts are hot potatoes that must be consumed, and the
// second settle re-inserts the intent id into the `intent_settled` VecSet, which aborts on the
// duplicate key. The whole PTB therefore reverts — no double-count is ever committed.
#[test]
#[expected_failure]
fun test_double_partial_settle_same_intent_reverts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, _id2) = drive_to_settlement(&mut sc, &mut clock);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id1);

    // id1: sell 1000, floor 2090 (= max(m_eff 1900, benchmark 2090))
    let (c1, r1) = settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
    // second take BEFORE any settle — guard `!is_intent_settled` still passes
    let (c2, r2) = settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
    // first settle marks id1 settled
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, r1, h::mint<USDC>(2_090, ts::ctx(&mut sc)));
    // second settle re-inserts id1 into intent_settled -> EKeyAlreadyExists -> whole PTB reverts
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, r2, h::mint<USDC>(2_090, ts::ctx(&mut sc)));

    h::burn(c1);
    h::burn(c2);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    ts::return_shared(intent);
    clock.destroy_for_testing();
    ts::end(sc);
}

// ============================================================================
// Audit review 001 — finding verification
// Each test below confirms (or refutes) an open finding from
// audits/001-2026-05-30-internal-stride.md before any fix is written.
// ============================================================================

/// Drive a single partial-fillable TOKA->USDC intent (sell 1000, min 1900, deadline `deadline`)
/// all the way to Settlement, with `SOLVER` as the committed winner (floor 2090, k = 2.0x).
fun drive_one_to_settlement(sc: &mut Scenario, clock: &mut Clock, deadline: u64): ID {
    clock.set_for_testing(1_000);
    ts::next_tx(sc, U1);
    let id;
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(sc)),
            1_900, MID, 500, true, true, deadline, clock, ts::ctx(sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(sc, SOLVER);
    register_solver(sc, AUC);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    ts::next_tx(sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id], vector[1_000], vector[2_090], false, 190, ts::ctx(sc));   // benchmark (seq 0)
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id], vector[1_000], vector[4_180], false, 2_090, ts::ctx(sc)); // winning (seq 1)
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 2_090, ts::ctx(sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock); // -> Settlement, settlement_deadline = 13_000 + 30_000 = 43_000
    id
}

/// Finding (Medium): a winning intent whose deadline falls before the protocol settlement deadline
/// can no longer be taken — `take_intent_full` aborts `EIntentExpired`, so the solver cannot settle.
#[test]
#[expected_failure(abort_code = reiy::settlement::EIntentExpired)]
fun test_expired_winning_intent_take_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_one_to_settlement(&mut sc, &mut clock, 15_000); // intent expires at 15_000

    // settlement deadline is 43_000, but the intent expired at 15_000
    clock.set_for_testing(16_000);
    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    // aborts EIntentExpired here; the rest is unreachable but must type-check / consume values
    let (sell, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, receipt, h::mint<USDC>(4_180, ts::ctx(&mut sc)));
    h::burn(sell);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Expired intents are not slashable during fallback.
#[test]
fun test_expired_intent_not_slashed_in_fallback() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let _id = drive_one_to_settlement(&mut sc, &mut clock, 15_000); // expires at 15_000

    // advance past settlement deadline (43_000); intent is long expired
    clock.set_for_testing(44_000);
    ts::next_tx(&mut sc, AUC); // anyone can trigger
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::trigger_fallback(
            &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
        );
        assert!(reg::stake_of(&registry, SOLVER) == STAKE_AMOUNT, 1);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 4);
        assert!(reg::slash_count(&registry, SOLVER) == 0, 2);
        assert!(auction::phase_code(&state) == 6, 3); // Failed
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Full drains must use the full-consume settlement path.
#[test]
#[expected_failure(abort_code = reiy::intent_book::EFillNotStrictlyPartial)]
fun test_full_drain_via_partial_rejected() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_one_to_settlement(&mut sc, &mut clock, DEADLINE);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    // fill == full remaining (1000) must abort EFillNotStrictlyPartial
    let (sell, receipt) =
        settlement::take_intent_partial(&mut state, &mut intent, 1_000, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, receipt, h::mint<USDC>(2_090, ts::ctx(&mut sc)));
    h::burn(sell);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    ts::return_shared(intent);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Strict partial fills keep the residual intent alive.
#[test]
fun test_strict_partial_fill_keeps_residual() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_one_to_settlement(&mut sc, &mut clock, DEADLINE);

    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (sell, receipt) =
            settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
        h::burn(sell);
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, receipt, h::mint<USDC>(2_090, ts::ctx(&mut sc)),
        );
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
        ts::return_shared(intent);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        assert!(intent_book::remaining_sell(&intent) == 600, 1); // 1000 - 400 residual
        ts::return_shared(intent);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_overpaid_fee_refunded() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_protocol_fee(&mut cfg, 200, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(
            &mut state, &cfg, &mut registry, &mut treasury,
            h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
        );
        assert!(reiy::treasury::total_collected(&treasury) == 62, 1);
        assert!(reiy::treasury::balance(&treasury) == 31, 3);
        ts::return_shared(treasury);
        ts::return_shared(registry);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        let fees = reiy::treasury::withdraw_protocol_fees(&mut treasury, 31, &cap, ts::ctx(&mut sc));
        assert!(reiy::treasury::balance(&treasury) == 0, 2);
        h::burn(fees);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(treasury);
    };
    clock.destroy_for_testing();
    ts::end(sc);
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
    register_solver(&mut sc, AUC);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // single pair but declared_multi = true
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000], vector[2_090], true, 190, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::auction::EStakeTooSmall)]
fun test_bid_stake_too_small_aborts() {
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
    register_solver(&mut sc, SOLVER); // stake = 2 SUI
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // huge score -> required stake = score*1.5 >> 2 SUI
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(
            &mut state, &cfg, &mut registry, &mut treasury,
            h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(treasury);
        ts::return_shared(registry);
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
    register_solver(&mut sc, AUC);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
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

#[test]
fun test_benchmark_fallback_slashes_auctioneer_reservation() {
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
    register_solver(&mut sc, AUC);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000], vector[2_090], false, 190, ts::ctx(&mut sc));
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 0);
        assert!(reg::reserved_stake_of(&registry, AUC) == 1_000_000_000, 1);
        ts::return_shared(registry);
    };

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::trigger_fallback(
            &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
        );
        assert!(reg::stake_of(&registry, SOLVER) == STAKE_AMOUNT, 2);
        assert!(reg::stake_of(&registry, AUC) == STAKE_AMOUNT - 1_000_000_000, 3);
        assert!(reg::reserved_stake_of(&registry, AUC) == 0, 4);
        assert!(reg::slash_count(&registry, AUC) == 1, 5);
        assert!(reiy::treasury::stake_balance(&treasury) == 1_000_000_000, 6);
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(registry);
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::trigger_fallback(
            &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
        );
        assert!(auction::phase_code(&state) == 6, 0); // Failed
        assert!(reg::stake_of(&registry, SOLVER) == STAKE_AMOUNT - 1_000_000_000, 1);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 4);
        assert!(reg::slash_count(&registry, SOLVER) == 1, 2);
        assert!(reiy::treasury::stake_balance(&treasury) == 1_000_000_000, 3);
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        let stake =
            reiy::treasury::withdraw_slashed_stake(&mut treasury, 1_000_000_000, &cap, ts::ctx(&mut sc));
        assert!(reiy::treasury::stake_balance(&treasury) == 0, 5);
        assert!(reiy::treasury::total_stake_slashed(&treasury) == 1_000_000_000, 6);
        h::burn(stake);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(treasury);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_fallback_bounty_splits_slashed_stake() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_fallback_bounty_bps(&mut cfg, 1_000, &cap); // 10%
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (_id1, _id2) = drive_to_settlement(&mut sc, &mut clock);

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::trigger_fallback(
            &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
        );
        assert!(reg::stake_of(&registry, SOLVER) == STAKE_AMOUNT - 1_000_000_000, 0);
        assert!(reiy::treasury::stake_balance(&treasury) == 900_000_000, 1);
        assert!(reiy::treasury::total_stake_slashed(&treasury) == 1_000_000_000, 2);
        assert!(reiy::treasury::total_fallback_bounty_paid(&treasury) == 100_000_000, 3);
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    ts::next_tx(&mut sc, AUC);
    {
        let bounty = ts::take_from_sender<sui::coin::Coin<SUI>>(&mut sc);
        assert!(bounty.value() == 100_000_000, 4);
        h::burn(bounty);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_at_fault_solver_gets_no_fallback_bounty() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_fallback_bounty_bps(&mut cfg, 1_000, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (_id1, _id2) = drive_to_settlement(&mut sc, &mut clock);

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::trigger_fallback(
            &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
        );
        assert!(reiy::treasury::stake_balance(&treasury) == 1_000_000_000, 0);
        assert!(reiy::treasury::total_stake_slashed(&treasury) == 1_000_000_000, 1);
        assert!(reiy::treasury::total_fallback_bounty_paid(&treasury) == 0, 2);
        ts::return_shared(treasury);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::ESettlementDeadlinePassed)]
fun test_take_after_settlement_deadline_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, _id2) = drive_to_settlement(&mut sc, &mut clock);

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id1);
    let (sell, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, receipt, h::mint<USDC>(4_180, ts::ctx(&mut sc)),
    );
    h::burn(sell);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EAllWinnersSettled)]
fun test_fallback_after_all_winners_settled_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, AUC);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
    settlement::trigger_fallback(
        &mut state, &mut registry, &cfg, &mut treasury, &clock, ts::ctx(&mut sc),
    );
    ts::return_shared(treasury);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_close_after_deadline_if_already_settled() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    clock.set_for_testing(50_000);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let mut treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        settlement::close_batch(
            &mut state, &cfg, &mut registry, &mut treasury,
            h::mint<USDC>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
        );
        assert!(auction::phase_code(&state) == 4, 0);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 1);
        ts::return_shared(treasury);
        ts::return_shared(registry);
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::ETreasuryNumeraireMismatch)]
fun test_close_wrong_treasury_numeraire_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_numeraire<TOKA>(&mut cfg, &cap);
        let _ = reiy::treasury::init_treasury<TOKA, SUI>(&cfg, &cap, ts::ctx(&mut sc));
        config::set_numeraire<USDC>(&mut cfg, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };

    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut treasury = ts::take_shared<ProtocolTreasury<TOKA, SUI>>(&mut sc);
    settlement::close_batch(
        &mut state, &cfg, &mut registry, &mut treasury,
        h::mint<TOKA>(100, ts::ctx(&mut sc)), &clock, ts::ctx(&mut sc),
    );
    ts::return_shared(treasury);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::config::EWrongCanonicalObject)]
fun test_submit_bid_wrong_registry_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);

    ts::next_tx(&mut sc, U1);
    let id;
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000, ts::ctx(&mut sc)),
            1_900, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    ts::next_tx(&mut sc, ADMIN);
    let foreign_id;
    {
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        foreign_id = reg::init_for_testing<SUI>(&cap, ts::ctx(&mut sc));
        ts::return_to_sender(&mut sc, cap);
    };

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared_by_id<SolverRegistry<SUI>>(&mut sc, foreign_id);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    auction::submit_bid(
        &mut state, &mut registry, &cfg,
        vector[id], vector[1_000], vector[2_090], false, 190, ts::ctx(&mut sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
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
    register_solver(&mut sc, AUC);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        // multi-pair bid (spans two pairs)
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
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
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc)); // bid 0 is multi -> reject
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}
