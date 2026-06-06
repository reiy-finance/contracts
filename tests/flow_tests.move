#[test_only]
/// End-to-end auction lifecycle tests: collection -> bid -> benchmark/allocation -> winner ->
/// settlement -> close, plus the key adversarial / abort paths and MVP fee tests.
module reiy::flow_tests;

use sui::sui::SUI;
use sui::clock::Clock;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::{Self as config, GlobalConfig, AdminCap};
use reiy::auction::{Self, AuctionState};
use reiy::fee_vault::{Self, FeeVault};
use reiy::intent_book::{Self, Intent};
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::treasury::ProtocolTreasury;
use reiy::settlement;
use reiy::test_helpers::{Self as h, USDC, TOKA};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;
const AUC: address = @0xA0;
const SOLVER2: address = @0xB2;
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

/// Close the batch: verify score/UCP, distribute solver rewards from FeeVault<USDC>, release reservations.
fun close_one(sc: &mut Scenario, clock: &Clock) {
    ts::next_tx(sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(sc);
    settlement::close_batch<USDC, SUI>(&mut state, &cfg, &mut registry, &mut vault, clock, ts::ctx(sc));
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);
}

// === full happy path ===

#[test]
fun test_full_lifecycle_happy() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);

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

    // --- Bid ---
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1, id2], vector[1_000, 500], vector[2_090, 1_045], false, 285, ts::ctx(&mut sc),
        );
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

    // --- Selection ---
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

    // --- advance to Settlement ---
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

    // --- settle id1 (gross 4180) and id2 (gross 2090) ---
    // With default fees (200ppm volume, 50% surplus, 0.98% cap, 1% max):
    //   id1: vol_fee=0, surplus_by_share=1045, surplus_by_cap=40, surplus=40, total=40 → net=4140
    //   id2: vol_fee=0, surplus_by_share=522,  surplus_by_cap=20, surplus=20, total=20 → net=2070
    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    // --- close ---
    close_one(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        assert!(auction::phase_code(&state) == 4, 200); // Close
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 201);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    // U1 receives net payouts: 4140 + 2070 = 6210 USDC
    ts::next_tx(&mut sc, U1);
    {
        let c1 = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        let c2 = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(c1.value() + c2.value() == 6_210, 300);
        h::burn(c1);
        h::burn(c2);
    };

    // Fee vault collected 40 + 20 = 60 USDC; at close, VCG reward of 30 (β=50% × 60) paid to
    // the sole winning SOLVER, leaving balance 30. total_collected stays 60 (cumulative).
    ts::next_tx(&mut sc, ADMIN);
    {
        let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        assert!(fee_vault::balance(&vault) == 30, 400);
        assert!(fee_vault::total_collected(&vault) == 60, 401);
        ts::return_shared(vault);
    };
    // Winning SOLVER received the 30 USDC VCG reward
    ts::next_tx(&mut sc, SOLVER);
    {
        let reward = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(reward.value() == 30, 402);
        h::burn(reward);
    };

    clock.destroy_for_testing();
    ts::end(sc);
}

fun settle_one(sc: &mut Scenario, id: ID, gross_payout: u64, clock: &Clock) {
    ts::next_tx(sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(sc, id);
    let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, clock, ts::ctx(sc));
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, &mut vault, receipt,
        h::mint<USDC>(gross_payout, ts::ctx(sc)), ts::ctx(sc),
    );
    h::burn(sell_coin);
    ts::return_shared(vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
}

/// Drive a standard TOKA->USDC batch all the way to Settlement phase.
/// Winning bid pays 4180/2090 gross (committed score 3135). Winning solver is `SOLVER`.
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

/// DoS bound: allocation count is capped by config.max_allocations. The reference-score
/// computation at close is O(solvers × allocations), so an unbounded allocation count would
/// let an attacker make close_batch arbitrarily expensive. Submitting past the cap aborts.
#[test]
#[expected_failure(abort_code = reiy::auction::EBatchLimitExceeded)]
fun test_max_allocations_cap_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    // Tighten the cap to 1 allocation
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_max_allocations(&mut cfg, 1, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
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
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000], vector[4_180], false, 2_090, ts::ctx(&mut sc));
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
        // First allocation OK (count 0 < cap 1)
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 2_090, ts::ctx(&mut sc));
        // Second allocation exceeds cap → EBatchLimitExceeded
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 2_090, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === MVP Fee Tests ===
// All tests below use gross amounts large enough to produce measurable PPM fees.
// Each intent: sell 1_000_000 TOKA, min 1_900_000, floor ≈ 1_900_000, gross = 2_000_000.
// protected_min = max(m_eff, floor). For simplicity these tests bypass the full
// auction lifecycle and use settle_intent_with_values_for_testing.

// Helper: run one small batch (1 intent, sell=1M TOKA, min=1.9M, gross=G) to Settlement
// and return the intent ID. Score committed = 100_000 (arbitrary).
fun drive_single_large_to_settlement(sc: &mut Scenario, clock: &mut Clock): ID {
    clock.set_for_testing(1_000);
    ts::next_tx(sc, U1);
    let id;
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
            &mut state, &cfg, h::mint<TOKA>(1_000_000, ts::ctx(sc)),
            1_900_000, MID, 500, true, false, DEADLINE, clock, ts::ctx(sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(sc, SOLVER);
    register_solver(sc, AUC);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    // bid: floor = sbbo ~ 1_900_000; gross = 2_000_000; score = 100_000
    ts::next_tx(sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
        let cfg = ts::take_shared<GlobalConfig>(sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id], vector[1_000_000], vector[1_900_000], false, 0, ts::ctx(sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id], vector[1_000_000], vector[2_000_000], false, 100_000, ts::ctx(sc));
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
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 100_000, ts::ctx(sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.set_for_testing(13_000);
    ts::next_tx(sc, ADMIN);
    advance(sc, clock);
    id
}

/// Volume fee 200 ppm on standard pair: 1_000_000 * 200 / 1_000_000 = 200.
#[test]
fun test_volume_fee_standard_200_ppm() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_single_large_to_settlement(&mut sc, &mut clock);

    // gross = 1_000_200 (volume: 200) + surplus cap = small
    // Let's use gross = 1_000_200 so volume_fee = 200 exactly
    // protected_min for sell=1_000_000, min=1_900_000, mid=2x → floor~1_900_000
    // Actually protected_min = max(m_eff=1_900_000, floor=1_900_000) = 1_900_000
    // Let's pick gross = 2_000_000:
    //   vol_fee = 2_000_000 * 200 / 1_000_000 = 400
    //   payout_after_vol = 1_999_600 >= 1_900_000 ✓
    //   surplus_after_vol = 1_999_600 - 1_900_000 = 99_600
    //   surplus_by_share = 99_600 * 500_000 / 1_000_000 = 49_800
    //   surplus_by_cap   = 2_000_000 * 9_800 / 1_000_000 = 19_600
    //   surplus_fee      = min(49_800, 19_600) = 19_600
    //   total_uncapped   = 400 + 19_600 = 20_000
    //   total_cap        = 2_000_000 * 10_000 / 1_000_000 = 20_000
    //   total_fee        = min(20_000, 20_000) = 20_000
    //   net              = 1_980_000
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, &mut vault, receipt,
            h::mint<USDC>(2_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc),
        );
        h::burn(sell_coin);
        // total_fee = 20_000 (1%)
        assert!(fee_vault::balance(&vault) == 20_000, 1);
        ts::return_shared(vault);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    // User receives 1_980_000 net
    ts::next_tx(&mut sc, U1);
    {
        let c = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(c.value() == 1_980_000, 2);
        h::burn(c);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Zero surplus (gross == protected_min) still charges volume fee, no surplus fee.
#[test]
fun test_zero_surplus_charges_volume_fee_only() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_single_large_to_settlement(&mut sc, &mut clock);

    // protected_min ~ 1_900_000; deliver exactly protected_min + volume_fee so surplus = 0
    // vol_fee = 1_900_200 * 200 / 1_000_000 = 380 (floor)
    // payout_after_vol = 1_900_200 - 380 = 1_899_820 < 1_900_000 → EBelowFloor
    // Use gross = 1_900_381: vol = 380, payout_after = 1_900_001 >= 1_900_000, surplus = 1 → tiny surplus fee
    // Simpler: let's pick protected_min = 1_000_200, gross = 1_000_400 → vol_fee=200 (floor(1_000_400*200/1M))
    // The floor for sell=1M, mid=2x, slippage=5% is ~1_900_000. Use a different approach:
    // Just pick gross = floor + some small amount so surplus is 0 after rounding.
    // gross = 1_900_200: vol_fee = floor(1_900_200 * 200 / 1_000_000) = floor(380.04) = 380
    // payout_after_vol = 1_900_200 - 380 = 1_899_820 < protected_min=1_900_000 → EBelowFloor!
    // Let gross = protected_min such that vol_fee leaves exactly protected_min:
    // gross * (1 - 200/1M) >= protected_min → gross >= 1_900_000 * 1M / 999_800 ≈ 1_900_380
    // Use gross = 1_900_381: vol=floor(1_900_381*200/1M)=floor(380.07)=380
    //   payout_after = 1_900_381 - 380 = 1_900_001 ≥ 1_900_000 ✓
    //   surplus_after = 1_900_001 - 1_900_000 = 1 (tiny)
    //   surplus_by_share = floor(1 * 500_000 / 1M) = 0
    //   surplus_fee = 0
    //   total = 380, net = 1_900_001
    // Close enough — volume fee only, no surplus fee.
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, &mut vault, receipt,
            h::mint<USDC>(1_900_381, ts::ctx(&mut sc)), ts::ctx(&mut sc),
        );
        h::burn(sell_coin);
        assert!(fee_vault::balance(&vault) == 380, 1); // only volume fee
        ts::return_shared(vault);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Total fee capped at 1% of gross (max_total_fee_ppm = 10_000).
#[test]
fun test_total_fee_capped_at_1_pct() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_single_large_to_settlement(&mut sc, &mut clock);

    // gross = 2_000_000:
    //   vol_fee = 400, surplus_after_vol = 99_600, surplus_by_share = 49_800, cap = 19_600
    //   total_uncapped = 400 + 19_600 = 20_000 = total_cap (2M * 10_000 / 1M)
    //   total_fee = 20_000 = 1% of gross ✓
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, &mut vault, receipt,
            h::mint<USDC>(2_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc),
        );
        h::burn(sell_coin);
        // total_fee must equal exactly 1% of gross = 20_000
        assert!(fee_vault::balance(&vault) == 20_000, 1);
        assert!(fee_vault::total_collected(&vault) == 20_000, 2);
        ts::return_shared(vault);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Settlement aborts when gross payout cannot cover volume fee + protected_min.
#[test]
#[expected_failure(abort_code = reiy::settlement::EBelowFloor)]
fun test_settle_aborts_if_gross_cannot_cover_fees_and_min() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_single_large_to_settlement(&mut sc, &mut clock);

    // protected_min ~ 1_900_000; deliver just barely enough to cover m_eff but
    // after volume_fee it falls below protected_min → EBelowFloor
    // gross = 1_900_001: vol_fee = floor(1_900_001 * 200 / 1M) = 380
    // payout_after_vol = 1_900_001 - 380 = 1_899_621 < 1_900_000 → EBelowFloor
    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, &mut vault, receipt,
        h::mint<USDC>(1_900_001, ts::ctx(&mut sc)), ts::ctx(&mut sc),
    );
    h::burn(sell_coin);
    ts::return_shared(vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Fee is split from Coin<Buy> and deposited into FeeVault<Buy>.
/// No Coin<N> close fee is required. close_batch works without fee coin.
#[test]
fun test_fee_split_into_vault_no_close_fee_required() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);

    // close_batch takes no fee coin — verify it succeeds
    close_one(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        assert!(auction::phase_code(&state) == 4, 0); // Close
        ts::return_shared(state);
    };
    // Fee vault holds fees collected during settlement
    ts::next_tx(&mut sc, ADMIN);
    {
        let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        // fees from tiny amounts: see happy path calculation (60 USDC)
        assert!(fee_vault::total_collected(&vault) == 60, 1);
        ts::return_shared(vault);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// close_batch does NOT withdraw solver reward from treasury.
/// Treasury balance stays 0 after close.
#[test]
fun test_close_does_not_pay_solver_reward_from_treasury() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);
    close_one(&mut sc, &clock);

    ts::next_tx(&mut sc, ADMIN);
    {
        let treasury = ts::take_shared<ProtocolTreasury<USDC, SUI>>(&mut sc);
        // treasury balance stays 0 — no rewards paid from it
        assert!(reiy::treasury::balance(&treasury) == 0, 0);
        assert!(reiy::treasury::total_collected(&treasury) == 0, 1);
        ts::return_shared(treasury);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// VCG solver reward: performanceReward = cap(actual - benchmark, β × fees)
/// Setup: fees=60, reward_share=50%, benchmark_score=285, actual_score=3135
///   performance_excess = 3135 - 285 = 2850
///   reward_cap = 50% × 60 = 30
///   total_reward = min(2850, 30) = 30
/// Solver receives 30 USDC from vault; vault balance = 60 - 30 = 30.
#[test]
fun test_solver_vcg_reward_paid_from_fee_vault() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    // Enable 50% solver reward share
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_solver_reward_share_ppm(&mut cfg, 500_000, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);
    close_one(&mut sc, &clock);

    // Vault: started with 60 fees, paid 30 reward → balance = 30
    ts::next_tx(&mut sc, ADMIN);
    {
        let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        assert!(fee_vault::total_collected(&vault) == 60, 0); // total_collected is cumulative
        assert!(fee_vault::balance(&vault) == 30, 1);         // 60 fees − 30 reward
        ts::return_shared(vault);
    };
    // SOLVER address received 30 USDC reward
    ts::next_tx(&mut sc, SOLVER);
    {
        let reward = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(reward.value() == 30, 2);
        h::burn(reward);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Governance can disable rewards by setting solver_reward_share_ppm = 0 → no reward paid.
#[test]
fun test_no_solver_reward_when_share_is_zero() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    // Disable rewards (override the 50% mainnet default)
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        config::set_solver_reward_share_ppm(&mut cfg, 0, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock);
    settle_one(&mut sc, id2, 2_090, &clock);
    close_one(&mut sc, &clock);

    ts::next_tx(&mut sc, ADMIN);
    {
        let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        assert!(fee_vault::balance(&vault) == 60, 0); // no reward paid
        ts::return_shared(vault);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// F-005-1 regression: a competing "paper" allocation must NOT suppress the winner's reward.
/// The reference is benchmark-only, so undeliverable losing allocations are ignored.
/// Single intent (sell 1M, min 1.9M):
///   - SOLVER  bid seq1: payout 2_000_000, score 100_000  → wins
///   - SOLVER2 bid seq2: payout 1_995_000, score  95_000  → competing allocation (the "paper" bid)
/// SOLVER settles at gross 2_000_000: total_fee = 20_000, cap = β×fee = 10_000.
///   referenceScore(SOLVER) = benchmark 0 (competing allocation 95_000 is IGNORED)
///   marginal = actual_score 100_000 − 0 = 100_000   (> cap → cap binds)
///   reward   = min(100_000, 10_000) = 10_000
/// If the reference still counted the competing allocation (pre-fix), reward would be the
/// suppressed 5_000 — so 10_000 verifies the griefing vector is closed.
#[test]
fun test_competing_allocation_does_not_suppress_reward() {
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
            &mut state, &cfg, h::mint<TOKA>(1_000_000, ts::ctx(&mut sc)),
            1_900_000, MID, 500, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
        );
        ts::return_shared(cfg);
        ts::return_shared(state);
    };
    register_solver(&mut sc, SOLVER);
    register_solver(&mut sc, AUC);
    register_solver(&mut sc, SOLVER2);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // SOLVER: seq0 (benchmark bid, payout=floor, score 0) + seq1 (winning, score 100_000)
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000_000], vector[1_900_000], false, 0, ts::ctx(&mut sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000_000], vector[2_000_000], false, 100_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    // SOLVER2: seq2 (alternative, payout 1_995_000, score 95_000)
    ts::next_tx(&mut sc, SOLVER2);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id1], vector[1_000_000], vector[1_995_000], false, 95_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    clock.set_for_testing(7_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // AUC: benchmark from seq0 + allocation [seq1]. SOLVER2: alternative allocation [seq2].
    ts::next_tx(&mut sc, AUC);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[1], 100_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    ts::next_tx(&mut sc, SOLVER2);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        auction::submit_allocation(&mut state, &mut registry, &cfg, vector[2], 95_000, ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };

    clock.set_for_testing(13_000);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);

    // SOLVER settles winning intent at gross 2_000_000
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id1);
        let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, &mut vault, receipt,
            h::mint<USDC>(2_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc),
        );
        h::burn(sell_coin);
        ts::return_shared(vault);
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    close_one(&mut sc, &clock);

    // reward = 10_000 (cap binds; competing allocation ignored → not suppressed to 5_000)
    ts::next_tx(&mut sc, SOLVER);
    {
        let reward = ts::take_from_sender<sui::coin::Coin<USDC>>(&mut sc);
        assert!(reward.value() == 10_000, 0);
        h::burn(reward);
    };
    ts::next_tx(&mut sc, ADMIN);
    {
        let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        assert!(fee_vault::balance(&vault) == 10_000, 1); // 20_000 fee − 10_000 reward
        ts::return_shared(vault);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Fee vault canonical ID mismatch aborts.
#[test]
#[expected_failure(abort_code = reiy::config::EWrongCanonicalObject)]
fun test_fee_vault_wrong_id_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_single_large_to_settlement(&mut sc, &mut clock);

    // Create a second (non-canonical) vault
    ts::next_tx(&mut sc, ADMIN);
    let foreign_vault_id;
    {
        let cap = ts::take_from_sender<AdminCap>(&mut sc);
        foreign_vault_id = fee_vault::init_fee_vault<USDC>(&cap, ts::ctx(&mut sc));
        ts::return_to_sender(&mut sc, cap);
    };

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut foreign_vault = ts::take_shared_by_id<FeeVault<USDC>>(&mut sc, foreign_vault_id);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let (sell_coin, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    // aborts EWrongCanonicalObject — foreign vault not registered in config
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, &mut foreign_vault, receipt,
        h::mint<USDC>(2_000_000, ts::ctx(&mut sc)), ts::ctx(&mut sc),
    );
    h::burn(sell_coin);
    ts::return_shared(foreign_vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// UCP: two intents with same sell amount receive same gross clearing price.
#[test]
fun test_ucp_same_sell_same_clearing_price() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    // Both intents: sell=1_000, same clearing price 4180/1000 = 4.18
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock); // sets UCP ref 4180/1000
    settle_one(&mut sc, id2, 2_090, &clock); // 2090/500 = 4.18 ✓
    close_one(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        assert!(auction::phase_code(&state) == 4, 0); // Close
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Score uses gross_payout - protected_min, not payout - floor.
#[test]
fun test_score_uses_gross_minus_protected_min() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);

    // Settle at exact floor values so created_surplus = 0
    // floor for id1 = max(m_eff=1900, bm=2090) = 2090
    // floor for id2 = max(m_eff=950, bm=1045) = 1045
    // gross=2090 → created_surplus=0; gross=1045 → created_surplus=0
    // actual_score = 0 < committed_score = 3135 → EScoreMismatch on close
    settle_one(&mut sc, id1, 2_090, &clock);
    settle_one(&mut sc, id2, 1_045, &clock);

    ts::next_tx(&mut sc, SOLVER);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        let actual = auction::current_epoch_score_surplus(&state);
        assert!(actual == 0, 0); // gross == protected_min → score = 0
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Partial fills compute protected minimum proportionally.
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
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (sell, receipt) =
            settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
        h::burn(sell);
        // ceil proportional m_eff for 400/1000 fill of 1900 = ceil(1900*400/1000) = 760
        // floor from benchmark_payout for this intent ≈ 2090*400/1000 = 836
        // protected_min = max(760, 836) = 836
        // gross=2_090 covers it (vol_fee=0, surplus_by_share huge, cap=20, total=20)
        settlement::settle_intent_numeraire(
            &mut state, &mut registry, &cfg, &mut vault, receipt,
            h::mint<USDC>(2_090, ts::ctx(&mut sc)), ts::ctx(&mut sc),
        );
        ts::return_shared(vault);
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

// === Double partial-take reversion ===

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
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id1);

    let (c1, r1) = settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
    let (c2, r2) = settlement::take_intent_partial(&mut state, &mut intent, 400, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, &mut vault, r1, h::mint<USDC>(2_090, ts::ctx(&mut sc)), ts::ctx(&mut sc));
    // second settle re-inserts id1 into intent_settled -> EKeyAlreadyExists -> whole PTB reverts
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, &mut vault, r2, h::mint<USDC>(2_090, ts::ctx(&mut sc)), ts::ctx(&mut sc));

    h::burn(c1);
    h::burn(c2);
    ts::return_shared(vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    ts::return_shared(intent);
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Audit finding tests ===

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
            vector[id], vector[1_000], vector[2_090], false, 190, ts::ctx(sc));
        auction::submit_bid(
            &mut state, &mut registry, &cfg,
            vector[id], vector[1_000], vector[4_180], false, 2_090, ts::ctx(sc));
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
    advance(sc, clock);
    id
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EIntentExpired)]
fun test_expired_winning_intent_take_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let id = drive_one_to_settlement(&mut sc, &mut clock, 15_000);

    clock.set_for_testing(16_000);
    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let (sell, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, &mut vault, receipt, h::mint<USDC>(4_180, ts::ctx(&mut sc)), ts::ctx(&mut sc));
    h::burn(sell);
    ts::return_shared(vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_expired_intent_not_slashed_in_fallback() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let _id = drive_one_to_settlement(&mut sc, &mut clock, 15_000);

    clock.set_for_testing(44_000);
    ts::next_tx(&mut sc, AUC);
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
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let (sell, receipt) =
        settlement::take_intent_partial(&mut state, &mut intent, 1_000, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(&mut state, &mut registry, &cfg, &mut vault, receipt, h::mint<USDC>(2_090, ts::ctx(&mut sc)), ts::ctx(&mut sc));
    h::burn(sell);
    ts::return_shared(vault);
    ts::return_shared(cfg);
    ts::return_shared(registry);
    ts::return_shared(state);
    ts::return_shared(intent);
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
            1_900, MID, 501, true, false, DEADLINE, &clock, ts::ctx(&mut sc),
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
    register_solver(&mut sc, SOLVER);
    ts::next_tx(&mut sc, ADMIN);
    advance(&mut sc, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
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
    // protected_min=2090; pay 2000 → vol_fee=0, payout_after_vol=2000 < 2090 → EBelowFloor
    settle_one(&mut sc, id1, 2_000, &clock);
    clock.destroy_for_testing();
    ts::end(sc);
}

/// Gross between m_eff and floor (m_eff=1900 < gross=2000 < floor=2090) → EBelowFloor.
/// protected_min = max(m_eff, floor) = 2090; vol_fee≈0; payout_after_volume=2000 < 2090.
#[test]
#[expected_failure(abort_code = reiy::settlement::EBelowFloor)]
fun test_settle_below_floor_but_above_min_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, _id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 2_000, &clock); // m_eff=1900 < 2000 < floor=2090 → EBelowFloor
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::auction::EBidEpsrInconsistent)]
fun test_settle_ucp_mismatch_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    let (id1, id2) = drive_to_settlement(&mut sc, &mut clock);
    settle_one(&mut sc, id1, 4_180, &clock);  // UCP ref: 4180/1000
    settle_one(&mut sc, id2, 1_100, &clock);  // 1100/500 ≠ 4180/1000 → EBidEpsrInconsistent
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
    // gross == protected_min → created_surplus = 0 → actual_score = 0 < committed 3135
    settle_one(&mut sc, id1, 2_090, &clock);
    settle_one(&mut sc, id2, 1_045, &clock);
    ts::next_tx(&mut sc, SOLVER);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
        settlement::close_batch<USDC, SUI>(&mut state, &cfg, &mut registry, &mut vault, &clock, ts::ctx(&mut sc));
        ts::return_shared(vault);
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
        assert!(auction::phase_code(&state) == 6, 0);
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
        config::set_fallback_bounty_bps(&mut cfg, 1_000, &cap);
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
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id1);
    let (sell, receipt) = settlement::take_intent_full(&mut state, intent, &clock, ts::ctx(&mut sc));
    settlement::settle_intent_numeraire(
        &mut state, &mut registry, &cfg, &mut vault, receipt,
        h::mint<USDC>(4_180, ts::ctx(&mut sc)), ts::ctx(&mut sc),
    );
    h::burn(sell);
    ts::return_shared(vault);
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
    close_one(&mut sc, &clock);
    ts::next_tx(&mut sc, ADMIN);
    {
        let state = ts::take_shared<AuctionState>(&mut sc);
        let registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
        assert!(auction::phase_code(&state) == 4, 0);
        assert!(reg::reserved_stake_of(&registry, SOLVER) == 0, 1);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

// === Wrong canonical objects ===

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
        auction::submit_pair_benchmark(&mut state, &mut registry, &cfg, vector[0], ts::ctx(&mut sc));
        ts::return_shared(cfg);
        ts::return_shared(registry);
        ts::return_shared(state);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}
