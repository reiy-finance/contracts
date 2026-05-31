// Copyright (c) Reiy Finance
module reiy::math;

const K_SCALE: u128 = 1_000_000_000;
const BPS_DENOM: u128 = 10_000;

#[error]
const EDivideByZero: vector<u8> = b"denominator must be non-zero";
#[error]
const EOverflow: vector<u8> = b"result exceeds u64::MAX";

public fun k_scale(): u64 { K_SCALE as u64 }

public fun bps_denom(): u64 { BPS_DENOM as u64 }

/// `floor(a * b / denom)` in u128.
public fun mul_div_floor(a: u64, b: u64, denom: u64): u64 {
    assert!(denom != 0, EDivideByZero);
    to_u64((a as u128) * (b as u128) / (denom as u128))
}

/// `ceil(a * b / denom)` in u128.
public fun mul_div_ceil(a: u64, b: u64, denom: u64): u64 {
    assert!(denom != 0, EDivideByZero);
    let num = (a as u128) * (b as u128);
    let d = denom as u128;
    to_u64((num + d - 1) / d)
}

public fun abs_diff_u128(a: u128, b: u128): u128 {
    if (a >= b) { a - b } else { b - a }
}

/// `floor(numerator * K_SCALE / denominator)` — fixed-point ratio for `actual_k`.
public fun fixed_ratio(numerator: u64, denominator: u64): u64 {
    assert!(denominator != 0, EDivideByZero);
    to_u64((numerator as u128) * K_SCALE / (denominator as u128))
}

/// EPSR cross-multiplication check with no tolerance:
/// `p_i / floor_i == p_ref / floor_ref`.
public fun cross_ratio_equal(
    p_i: u64,
    floor_i: u64,
    p_ref: u64,
    floor_ref: u64,
): bool {
    (p_i as u128) * (floor_ref as u128) == (p_ref as u128) * (floor_i as u128)
}

public fun to_u64(x: u128): u64 {
    assert!(x <= (std::u64::max_value!() as u128), EOverflow);
    x as u64
}
