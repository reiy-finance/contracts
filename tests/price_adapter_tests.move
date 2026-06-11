#[test_only]
module reiy::price_adapter_tests;

use reiy::price_adapter as pa;

const K: u64 = 1_000_000_000; // FLOAT_SCALING

#[test]
fun test_expected_out_base_to_quote() {
    // selling 1_000 base at mid price 2.0x (2*K) -> 2_000 quote
    assert!(pa::expected_out_base_to_quote(1_000, 2 * K) == 2_000, 0);
    // mid 0.5x -> 500
    assert!(pa::expected_out_base_to_quote(1_000, K / 2) == 500, 1);
}

#[test]
fun test_expected_out_quote_to_base() {
    // selling 2_000 quote at mid 2.0x -> 1_000 base
    assert!(pa::expected_out_quote_to_base(2_000, 2 * K) == 1_000, 0);
}

#[test]
fun test_apply_slippage_floor_uses_ceil() {
    // expected 1_000, sigma 500 bps (5%) -> 950
    assert!(pa::apply_slippage_floor(1_000, 500) == 950, 0);
    // ceil behavior: expected 1_001, 5% -> 1_001*9500/10000 = 950.95 -> ceil 951
    assert!(pa::apply_slippage_floor(1_001, 500) == 951, 1);
    // zero slippage -> unchanged
    assert!(pa::apply_slippage_floor(777, 0) == 777, 2);
}

#[test]
fun test_sbbo_floor_base_to_quote() {
    // 1_000 base @ 2.0x, 5% slippage -> expected 2_000 -> 1_900
    assert!(pa::sbbo_floor_base_to_quote(1_000, 2 * K, 500) == 1_900, 0);
}

#[test]
fun test_sbbo_floor_quote_to_base() {
    // 2_000 quote @ 2.0x, 5% slippage -> expected 1_000 -> 950
    assert!(pa::sbbo_floor_quote_to_base(2_000, 2 * K, 500) == 950, 0);
}

#[test]
fun test_sbbo_directions_differ() {
    // same amount + mid, opposite directions yield different floors (direction matters)
    let a = pa::sbbo_floor_base_to_quote(1_000, 3 * K, 0);
    let b = pa::sbbo_floor_quote_to_base(1_000, 3 * K, 0);
    assert!(a != b, 0);
    assert!(a == 3_000, 1);            // 1_000 * 3
    assert!(b == 333, 2);              // 1_000 / 3 floored
}

#[test]
fun test_normalize_roundtrip_scales() {
    // normalize base->quote at price 2x: 100 base -> 200 quote
    assert!(pa::normalize_base_to_quote(100, 2 * K) == 200, 0);
    // normalize quote->base at price 2x: 200 quote -> 100 base
    assert!(pa::normalize_quote_to_base(200, 2 * K) == 100, 1);
}

#[test]
fun test_decimals_6_vs_9_scaling() {
    // Simulate a USDC(6 dp)/SUI(9 dp) style pool where price already bakes in decimals.
    // selling 1_000_000 (1 USDC, 6dp) base at price encoding 1 SUI per USDC...
    // here we just assert the pure scaling stays consistent at a representative price.
    let mid = 4_000_000_000; // 4.0x
    assert!(pa::expected_out_base_to_quote(250_000, mid) == 1_000_000, 0);
}
