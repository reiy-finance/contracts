// Copyright (c) Reiy Finance

/// DeepBook price reader and pure SBBO / normalization helpers.
module reiy::price_adapter;

use deepbook::pool::Pool;
use reiy::config::GlobalConfig;
use reiy::math;
use sui::clock::Clock;

const FLOAT_SCALING: u64 = 1_000_000_000;

#[error]
const EPriceUnavailable: vector<u8> = b"deepbook mid price below configured minimum";

public fun float_scaling(): u64 { FLOAT_SCALING }

/// Expected quote out for `base_amount`: `base * mid / 1e9`.
public fun expected_out_base_to_quote(base_amount: u64, mid_price: u64): u64 {
    math::mul_div_floor(base_amount, mid_price, FLOAT_SCALING)
}

/// Expected base out for `quote_amount`: `quote * 1e9 / mid`.
public fun expected_out_quote_to_base(quote_amount: u64, mid_price: u64): u64 {
    math::mul_div_floor(quote_amount, FLOAT_SCALING, mid_price)
}

/// Apply slippage bps to an expected output (ceil — never rounds below floor).
public fun apply_slippage_floor(expected_out: u64, sigma_bps: u64): u64 {
    math::mul_div_ceil(expected_out, math::bps_denom() - sigma_bps, math::bps_denom())
}

/// SBBO floor when the sold token is the pool's BASE.
public fun sbbo_floor_base_to_quote(sell_amount: u64, mid_price: u64, sigma_bps: u64): u64 {
    apply_slippage_floor(expected_out_base_to_quote(sell_amount, mid_price), sigma_bps)
}

/// SBBO floor when the sold token is the pool's QUOTE.
public fun sbbo_floor_quote_to_base(sell_amount: u64, mid_price: u64, sigma_bps: u64): u64 {
    apply_slippage_floor(expected_out_quote_to_base(sell_amount, mid_price), sigma_bps)
}

/// Convert a BASE amount into QUOTE units at the supplied mid price.
public fun normalize_base_to_quote(amount: u64, price: u64): u64 {
    math::mul_div_floor(amount, price, FLOAT_SCALING)
}

/// Convert a QUOTE amount into BASE units at the supplied mid price.
public fun normalize_quote_to_base(amount: u64, price: u64): u64 {
    math::mul_div_floor(amount, FLOAT_SCALING, price)
}

/// Read DeepBook mid price and assert it meets the configured minimum.
public fun read_mid_price<Base, Quote>(
    pool: &Pool<Base, Quote>,
    config: &GlobalConfig,
    clock: &Clock,
): u64 {
    let mid = pool.mid_price(clock);
    assert!(mid >= config.min_sbbo_mid_price(), EPriceUnavailable);
    mid
}
