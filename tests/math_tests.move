#[test_only]
module reiy::math_tests;

use reiy::math;

const K: u64 = 1_000_000_000;

#[test]
fun test_mul_div_floor_basic() {
    assert!(math::mul_div_floor(10, 10, 4) == 25, 0);
    assert!(math::mul_div_floor(7, 1, 2) == 3, 1); // 3.5 -> 3
    assert!(math::mul_div_floor(0, 999, 7) == 0, 2);
}

#[test]
fun test_mul_div_ceil_basic() {
    assert!(math::mul_div_ceil(7, 1, 2) == 4, 0); // 3.5 -> 4
    assert!(math::mul_div_ceil(10, 10, 4) == 25, 1); // exact -> 25
    assert!(math::mul_div_ceil(101, 1, 100) == 2, 2); // 1.01 -> 2 (adversarial partial-fill case)
    assert!(math::mul_div_ceil(100, 1, 100) == 1, 3); // exact -> 1
}

#[test]
fun test_ceil_ge_floor() {
    let a = 12345; let b = 6789; let d = 1000;
    assert!(math::mul_div_ceil(a, b, d) >= math::mul_div_floor(a, b, d), 0);
}

#[test]
fun test_abs_diff() {
    assert!(math::abs_diff_u128(10, 3) == 7, 0);
    assert!(math::abs_diff_u128(3, 10) == 7, 1);
    assert!(math::abs_diff_u128(5, 5) == 0, 2);
}

#[test]
fun test_fixed_ratio() {
    assert!(math::fixed_ratio(100, 100) == K, 0);       // 1.0x
    assert!(math::fixed_ratio(105, 100) == K + K / 20, 1); // 1.05x
    assert!(math::fixed_ratio(50, 100) == K / 2, 2);
}

#[test]
fun test_cross_ratio_equal() {
    assert!(math::cross_ratio_equal(105, 100, 210, 200), 0);
    assert!(!math::cross_ratio_equal(106, 100, 105, 100), 1);
    assert!(!math::cross_ratio_equal(10501, 10000, 105, 100), 2);
}

#[test]
#[expected_failure(abort_code = reiy::math::EDivideByZero)]
fun test_mul_div_floor_zero_denom_aborts() {
    math::mul_div_floor(1, 1, 0);
}

#[test]
#[expected_failure(abort_code = reiy::math::EDivideByZero)]
fun test_mul_div_ceil_zero_denom_aborts() {
    math::mul_div_ceil(1, 1, 0);
}

#[test]
#[expected_failure(abort_code = reiy::math::EDivideByZero)]
fun test_fixed_ratio_zero_denom_aborts() {
    math::fixed_ratio(1, 0);
}

#[test]
#[expected_failure(abort_code = reiy::math::EOverflow)]
fun test_to_u64_overflow_aborts() {
    // (u64::MAX) * 2 / 1 overflows u64 on narrowing
    math::mul_div_floor(18_446_744_073_709_551_615, 2, 1);
}

#[test]
fun test_u128_intermediate_no_overflow() {
    // large product fits in u128 and narrows back fine: (1e18 * 1e9) / 1e9 = 1e18
    let r = math::mul_div_floor(1_000_000_000_000_000_000, 1_000_000_000, 1_000_000_000);
    assert!(r == 1_000_000_000_000_000_000, 0);
}
