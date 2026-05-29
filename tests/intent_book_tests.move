#[test_only]
module reiy::intent_book_tests;

use sui::clock::Clock;
use sui::coin;
use sui::test_scenario::{Self as ts, Scenario};
use reiy::config::GlobalConfig;
use reiy::auction::{Self, AuctionState};
use reiy::intent_book::{Self, Intent};
use reiy::test_helpers::{Self as h, USDC, TOKA};

const ADMIN: address = @0xAD;
const U1: address = @0x1;
const MID: u64 = 2_000_000_000;
const DEADLINE: u64 = 10_000_000;

fun submit(sc: &mut Scenario, clock: &Clock, sell: u64, min_out: u64, partial: bool): ID {
    ts::next_tx(sc, U1);
    let mut state = ts::take_shared<AuctionState>(sc);
    let cfg = ts::take_shared<GlobalConfig>(sc);
    let id = auction::submit_intent_with_price_for_testing<TOKA, USDC>(
        &mut state, &cfg, h::mint<TOKA>(sell, ts::ctx(sc)),
        min_out, MID, 500, true, partial, DEADLINE, clock, ts::ctx(sc),
    );
    ts::return_shared(cfg);
    ts::return_shared(state);
    id
}

#[test]
fun test_create_stores_metadata_and_locks() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    let id = submit(&mut sc, &clock, 1_000, 1_900, false);
    ts::next_tx(&mut sc, U1);
    {
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        assert!(intent_book::owner(&intent) == U1, 0);
        assert!(intent_book::remaining_sell(&intent) == 1_000, 1);
        assert!(intent_book::min_amount_out(&intent) == 1_900, 2);
        assert!(intent_book::sbbo_floor(&intent) == 1_900, 3); // 1000*2*0.95
        assert!(intent_book::sbbo_mid_price(&intent) == MID, 4);
        assert!(intent_book::original_sell_amount(&intent) == 1_000, 5);
        ts::return_shared(intent);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_partial_consume_uses_ceil_minimum() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    // min 1900 over 1000 sell; fill 333 -> ceil(1900*333/1000) = ceil(632.7) = 633
    let id = submit(&mut sc, &clock, 1_000, 1_900, true);
    ts::next_tx(&mut sc, ADMIN);
    {
        let mut intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        let (owner, bal, m_eff) = intent_book::consume_intent_partial(&mut intent, 333);
        assert!(owner == U1, 0);
        assert!(m_eff == 633, 1); // CEIL, not floor (632)
        assert!(bal.value() == 333, 2);
        assert!(intent_book::remaining_sell(&intent) == 667, 3);
        assert!(intent_book::filled_amount(&intent) == 333, 4);
        coin::burn_for_testing(coin::from_balance(bal, ts::ctx(&mut sc)));
        ts::return_shared(intent);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}

#[test]
fun test_cancel_returns_full_balance() {
    let mut sc = ts::begin(ADMIN);
    h::setup_all(&mut sc, ADMIN);
    ts::next_tx(&mut sc, ADMIN);
    let mut clock = h::new_clock(ts::ctx(&mut sc));
    clock.set_for_testing(1_000);
    let id = submit(&mut sc, &clock, 1_000, 1_900, false);
    ts::next_tx(&mut sc, U1);
    {
        let mut state = ts::take_shared<AuctionState>(&mut sc);
        let intent = ts::take_shared_by_id<Intent<TOKA, USDC>>(&mut sc, id);
        auction::cancel_intent(&mut state, intent, ts::ctx(&mut sc));
        ts::return_shared(state);
    };
    ts::next_tx(&mut sc, U1);
    {
        let c = ts::take_from_sender<coin::Coin<TOKA>>(&mut sc);
        assert!(c.value() == 1_000, 0);
        h::burn(c);
    };
    clock.destroy_for_testing();
    ts::end(sc);
}
