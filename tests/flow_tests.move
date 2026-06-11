#[test_only]
module reiy::flow_tests;

use reiy::auction::{Self, AuctionState};
use reiy::config::{Self as config, GlobalConfig};
use reiy::fee_vault::{Self, FeeVault};
use reiy::intent_book::{Self, Intent};
use reiy::settlement;
use reiy::solver_registry::{Self as reg, SolverRegistry};
use reiy::test_helpers::{Self as h, TOKA, TOKB, USDC};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const SOLVER: address = @0x5;
const SOLVER2: address = @0xB2;
const USER: address = @0x1;

const MID: u64 = 2_000_000_000;
const DEADLINE: u64 = 10_000_000;
const STAKE_AMOUNT: u64 = 2_000_000_000;
const BAD_SIG: vector<u8> =
    x"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

fun register_solver(sc: &mut Scenario, who: address) {
    ts::next_tx(sc, who);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    reg::register_solver(&mut registry, &cfg, h::mint<SUI>(STAKE_AMOUNT, ts::ctx(sc)), b"http://solver", ts::ctx(sc));
    ts::return_shared(cfg);
    ts::return_shared(registry);
}

fun submit(sc: &mut Scenario, clock: &Clock, sell: u64, min_out: u64, partial: bool): ID {
    ts::next_tx(sc, USER);
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
        partial,
        DEADLINE,
        clock,
        ts::ctx(sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    id
}

fun settle_full(sc: &mut Scenario, clock: &Clock, solver: address, id: ID, sell: u64, gross: u64, protected_min: u64) {
    ts::next_tx(sc, solver);
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, USDC>(
        &state,
        b"solution",
        solver,
        vector[id],
        vector[sell],
        vector[gross],
        vector[protected_min],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_full(&mut state, &mut auth, intent, clock, ts::ctx(sc));
    h::burn(sell_coin);
    settlement::settle_intent(
        &mut state,
        &mut registry,
        &cfg,
        &mut vault,
        receipt,
        h::mint<USDC>(gross, ts::ctx(sc)),
        ts::ctx(sc),
    );
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);
}

#[test]
fun test_valid_certificate_settles_full_intent_and_splits_fee() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc, SOLVER);

    let id = submit(&mut sc, &clock, 10_000, 19_000, false);
    settle_full(&mut sc, &clock, SOLVER, id, 10_000, 20_000, 19_000);

    ts::next_tx(&mut sc, USER);
    let payout = ts::take_from_sender<Coin<USDC>>(&mut sc);
    assert!(payout.value() == 19_979, 0);
    h::burn(payout);

    ts::next_tx(&mut sc, SOLVER);
    let solver_fee = ts::take_from_sender<Coin<USDC>>(&mut sc);
    assert!(solver_fee.value() == 7, 1);
    h::burn(solver_fee);

    ts::next_tx(&mut sc, ADMIN);
    let state = ts::take_shared<AuctionState>(&mut sc);
    let vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    assert!(auction::settled_intent_count(&state) == 1, 2);
    assert!(auction::total_protocol_fee(&state) == 14, 3);
    assert!(auction::total_solver_fee(&state) == 7, 4);
    assert!(fee_vault::balance(&vault) == 14, 5);
    ts::return_shared(vault);
    ts::return_shared(state);

    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_non_usdc_buy_settles_and_collects_fee_in_buy_token() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    {
        let mut cfg = ts::take_shared<GlobalConfig>(&mut sc);
        let cap = ts::take_from_sender<reiy::config::AdminCap>(&mut sc);
        config::add_supported_pair<TOKA, TOKB>(&mut cfg, &cap);
        ts::return_to_sender(&mut sc, cap);
        ts::return_shared(cfg);
    };
    register_solver(&mut sc, SOLVER);

    ts::next_tx(&mut sc, USER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let id = auction::submit_intent_with_price_for_testing<TOKA, TOKB>(
        &mut state,
        &cfg,
        h::mint<TOKA>(10_000, ts::ctx(&mut sc)),
        19_000,
        MID,
        500,
        true,
        false,
        DEADLINE,
        &clock,
        ts::ctx(&mut sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<TOKB>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, TOKB>>(&mut sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, TOKB>(
        &state,
        b"tokb-solution",
        SOLVER,
        vector[id],
        vector[10_000],
        vector[20_000],
        vector[19_000],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_full(&mut state, &mut auth, intent, &clock, ts::ctx(&mut sc));
    h::burn(sell_coin);
    settlement::settle_intent(
        &mut state,
        &mut registry,
        &cfg,
        &mut vault,
        receipt,
        h::mint<TOKB>(20_000, ts::ctx(&mut sc)),
        ts::ctx(&mut sc),
    );
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);

    ts::next_tx(&mut sc, USER);
    let payout = ts::take_from_sender<Coin<TOKB>>(&mut sc);
    assert!(payout.value() == 19_979, 0);
    h::burn(payout);

    ts::next_tx(&mut sc, SOLVER);
    let solver_fee = ts::take_from_sender<Coin<TOKB>>(&mut sc);
    assert!(solver_fee.value() == 7, 1);
    h::burn(solver_fee);

    ts::next_tx(&mut sc, ADMIN);
    let vault = ts::take_shared<FeeVault<TOKB>>(&mut sc);
    assert!(fee_vault::balance(&vault) == 14, 2);
    ts::return_shared(vault);

    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_valid_certificate_settles_partial_intent_and_advances_target_epoch() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc, SOLVER);

    let id = submit(&mut sc, &clock, 1_000, 1_900, true);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, USDC>(
        &state,
        b"partial",
        SOLVER,
        vector[id],
        vector[400],
        vector[800],
        vector[760],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_partial(&mut state, &mut auth, &mut intent, &clock, ts::ctx(&mut sc));
    assert!(sell_coin.value() == 400, 0);
    h::burn(sell_coin);
    settlement::settle_intent(
        &mut state,
        &mut registry,
        &cfg,
        &mut vault,
        receipt,
        h::mint<USDC>(800, ts::ctx(&mut sc)),
        ts::ctx(&mut sc),
    );
    ts::return_shared(intent);
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);

    ts::next_tx(&mut sc, USER);
    let payout = ts::take_from_sender<Coin<USDC>>(&mut sc);
    assert!(payout.value() == 800, 1);
    h::burn(payout);

    ts::next_tx(&mut sc, ADMIN);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    assert!(intent_book::remaining_sell(&intent) == 600, 2);
    assert!(intent_book::target_epoch(&intent) == 1, 3);
    ts::return_shared(intent);

    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::ENotAuthorizedSolver)]
fun test_wrong_solver_cannot_verify_certificate() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    let id = submit(&mut sc, &clock, 10_000, 19_000, false);

    ts::next_tx(&mut sc, SOLVER2);
    let state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    settlement::verify_solution<TOKA, USDC>(
        &state,
        &cfg,
        b"wrong-solver",
        SOLVER,
        vector[id],
        vector[10_000],
        vector[20_000],
        vector[19_000],
        DEADLINE,
        BAD_SIG,
        &clock,
        ts::ctx(&mut sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EBadSolutionSignature)]
fun test_wrong_coordinator_signature_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    let id = submit(&mut sc, &clock, 10_000, 19_000, false);

    ts::next_tx(&mut sc, SOLVER);
    let state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    settlement::verify_solution<TOKA, USDC>(
        &state,
        &cfg,
        b"bad-signature",
        SOLVER,
        vector[id],
        vector[10_000],
        vector[20_000],
        vector[19_000],
        DEADLINE,
        BAD_SIG,
        &clock,
        ts::ctx(&mut sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EExpiredSolution)]
fun test_expired_certificate_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(5_000);
    let id = submit(&mut sc, &clock, 10_000, 19_000, false);

    ts::next_tx(&mut sc, SOLVER);
    let state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    settlement::verify_solution<TOKA, USDC>(
        &state,
        &cfg,
        b"expired",
        SOLVER,
        vector[id],
        vector[10_000],
        vector[20_000],
        vector[19_000],
        4_999,
        BAD_SIG,
        &clock,
        ts::ctx(&mut sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EWrongEpoch)]
fun test_wrong_epoch_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc, SOLVER);
    let id = submit(&mut sc, &clock, 1_000, 1_900, false);

    ts::next_tx(&mut sc, ADMIN);
    clock.set_for_testing(11_000);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    auction::advance_epoch(&mut state, &cfg, &clock);
    ts::return_shared(cfg);
    ts::return_shared(state);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, USDC>(
        &state,
        b"wrong-epoch",
        SOLVER,
        vector[id],
        vector[1_000],
        vector[2_000],
        vector[1_900],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_full(&mut state, &mut auth, intent, &clock, ts::ctx(&mut sc));
    h::burn(sell_coin);
    settlement::settle_intent(
        &mut state,
        &mut registry,
        &cfg,
        &mut vault,
        receipt,
        h::mint<USDC>(2_000, ts::ctx(&mut sc)),
        ts::ctx(&mut sc),
    );
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
#[expected_failure(abort_code = reiy::settlement::EBelowProtectedMinimum)]
fun test_tampered_protected_min_aborts() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc, SOLVER);
    let id = submit(&mut sc, &clock, 1_000, 1_900, false);

    ts::next_tx(&mut sc, SOLVER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let cfg = ts::take_shared<GlobalConfig>(&mut sc);
    let mut registry = ts::take_shared<SolverRegistry<SUI>>(&mut sc);
    let mut vault = ts::take_shared<FeeVault<USDC>>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    let mut auth = settlement::authorize_for_testing<TOKA, USDC>(
        &state,
        b"tampered",
        SOLVER,
        vector[id],
        vector[1_000],
        vector[2_000],
        vector[1_899],
    );
    let (sell_coin, receipt) =
        settlement::take_authorized_intent_full(&mut state, &mut auth, intent, &clock, ts::ctx(&mut sc));
    h::burn(sell_coin);
    settlement::settle_intent(
        &mut state,
        &mut registry,
        &cfg,
        &mut vault,
        receipt,
        h::mint<USDC>(2_000, ts::ctx(&mut sc)),
        ts::ctx(&mut sc),
    );
    ts::return_shared(vault);
    ts::return_shared(registry);
    ts::return_shared(cfg);
    ts::return_shared(state);
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_user_cancel_before_settlement_works() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    let id = submit(&mut sc, &clock, 1_000, 1_900, false);

    ts::next_tx(&mut sc, USER);
    let mut state = ts::take_shared<AuctionState>(&mut sc);
    let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
    auction::cancel_intent(&mut state, intent, ts::ctx(&mut sc));
    ts::return_shared(state);

    ts::next_tx(&mut sc, USER);
    let returned = ts::take_from_sender<Coin<TOKA>>(&mut sc);
    assert!(returned.value() == 1_000, 0);
    h::burn(returned);

    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_failed_solver_can_be_replaced_by_new_certificate() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    register_solver(&mut sc, SOLVER);
    register_solver(&mut sc, SOLVER2);
    let id = submit(&mut sc, &clock, 10_000, 19_000, false);

    ts::next_tx(&mut sc, SOLVER);
    let state = ts::take_shared<AuctionState>(&mut sc);
    let _unused = settlement::authorize_for_testing<TOKA, USDC>(
        &state,
        b"stale",
        SOLVER,
        vector[id],
        vector[10_000],
        vector[20_000],
        vector[19_000],
    );
    ts::return_shared(state);

    settle_full(&mut sc, &clock, SOLVER2, id, 10_000, 20_000, 19_000);

    ts::next_tx(&mut sc, USER);
    let payout = ts::take_from_sender<Coin<USDC>>(&mut sc);
    assert!(payout.value() == 19_979, 0);
    h::burn(payout);

    ts::next_tx(&mut sc, SOLVER2);
    let solver_fee = ts::take_from_sender<Coin<USDC>>(&mut sc);
    assert!(solver_fee.value() == 7, 1);
    h::burn(solver_fee);

    clock.destroy_for_testing();
    ts::end(sc);
}
