// Copyright (c) Reiy Finance

/// Protocol parameters, AdminCap, and allowlists. All mutations require AdminCap.
module reiy::config;

use reiy::events;
use reiy::types::{Self, PairKey};
use std::type_name::{Self, TypeName};
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

const ROLE_CONFIG_ADMIN: u64 = 0;

// === Bounds ===
const MAX_SLIPPAGE_BPS: u64 = 2_000;
const MIN_GRIEF_FACTOR_BPS: u64 = 10_000;
const MAX_FALLBACK_BOUNTY_BPS: u64 = 1_000;

// PPM fee bounds (parts-per-million, denominator 1_000_000)
const MAX_VOLUME_FEE_PPM: u64 = 10_000;      // 1.00%
const MAX_SURPLUS_FEE_PPM: u64 = 1_000_000;  // 100%
const MAX_SURPLUS_FEE_CAP_PPM: u64 = 20_000; // 2.00%
const MAX_TOTAL_FEE_PPM: u64 = 20_000;       // 2.00%
const MAX_SOLVER_REWARD_SHARE_PPM: u64 = 1_000_000;

// === Defaults ===
const DEFAULT_COLLECTION_MS: u64 = 10_000;
const DEFAULT_BID_MS: u64 = 5_000;
const DEFAULT_SELECTION_MS: u64 = 5_000;
const DEFAULT_SETTLEMENT_DEADLINE_MS: u64 = 30_000;
const DEFAULT_MIN_BATCH_COLLECT_MS: u64 = 10_000;
const DEFAULT_MIN_SOLVER_STAKE: u64 = 1_000_000_000;
const DEFAULT_GRIEF_FACTOR_BPS: u64 = 15_000;
const DEFAULT_ALLOCATION_STAKE: u64 = 1_000_000_000;
const DEFAULT_BENCHMARK_STAKE: u64 = 1_000_000_000;
const DEFAULT_FALLBACK_BOUNTY_BPS: u64 = 0;
const DEFAULT_MAX_ALLOCATION_BIDS: u64 = 32;
const DEFAULT_MAX_ALLOCATION_INTENTS: u64 = 128;
const DEFAULT_MAX_ALLOCATION_PAIRS: u64 = 16;
const DEFAULT_MAX_SLIPPAGE_BPS: u64 = 500;
const DEFAULT_MIN_SBBO_MID_PRICE: u64 = 1;
const DEFAULT_PRICE_ORACLE_MAX_AGE_MS: u64 = 60_000;

// MVP fee defaults
const DEFAULT_STANDARD_VOLUME_FEE_PPM: u64 = 200;       // 2 bps
const DEFAULT_CORRELATED_VOLUME_FEE_PPM: u64 = 30;      // 0.3 bps
const DEFAULT_SURPLUS_FEE_PPM: u64 = 500_000;           // 50%
const DEFAULT_SURPLUS_FEE_CAP_PPM: u64 = 9_800;         // 0.98% of gross
const DEFAULT_MAX_TOTAL_FEE_PPM: u64 = 10_000;          // 1.00%
const DEFAULT_SOLVER_REWARD_SHARE_PPM: u64 = 0;         // no on-chain reward in MVP
const DEFAULT_MAX_UCP_ROUNDING_LOSS: u64 = 1;

#[error]
const ENotAdmin: vector<u8> = b"caller lacks ROLE_CONFIG_ADMIN";
#[error]
const EInvalidParam: vector<u8> = b"parameter out of allowed bounds";
#[error]
const ENumeraireNotSet: vector<u8> = b"numeraire type not configured";
#[error]
const EPairNotSupported: vector<u8> = b"directed pair not on allowlist";
#[error]
const ECanonicalObjectNotSet: vector<u8> = b"canonical object not configured";
#[error]
const ECanonicalObjectAlreadySet: vector<u8> = b"canonical object already configured";
#[error]
const EWrongCanonicalObject: vector<u8> = b"wrong canonical object";
#[error]
const EFeeVaultNotRegistered: vector<u8> = b"fee vault not registered for this token";

/// Owned capability gating all mutations.
public struct AdminCap has key, store { id: UID }

public struct ACL has store {
    members: Table<address, vector<u64>>,
}

/// Fee tier per directed pair. Standard is the default for any pair not in pair_fee_tiers.
public enum FeeTier has copy, drop, store {
    Standard,
    Correlated,
    Custom(u64),
    Disabled,
}

/// Shared protocol configuration and canonical object bindings.
public struct GlobalConfig has key {
    id: UID,
    version: u64,
    collection_duration_ms: u64,
    bid_duration_ms: u64,
    selection_duration_ms: u64,
    settlement_deadline_ms: u64,
    min_batch_collect_ms: u64,
    // PPM fee parameters (parts-per-million, denominator 1_000_000)
    standard_volume_fee_ppm: u64,
    correlated_volume_fee_ppm: u64,
    surplus_fee_ppm: u64,
    surplus_fee_cap_ppm: u64,
    max_total_fee_ppm: u64,
    solver_reward_fee_share_ppm: u64,
    max_ucp_rounding_loss: u64,
    // Stake / grief
    min_solver_stake: u64,
    grief_factor_bps: u64,
    required_allocation_stake: u64,
    required_benchmark_stake: u64,
    fallback_bounty_bps: u64,
    // Limits
    max_allocation_bids: u64,
    max_allocation_intents: u64,
    max_allocation_pairs: u64,
    max_slippage_tolerance_bps: u64,
    min_sbbo_mid_price: u64,
    price_oracle_max_age_ms: u64,
    // Canonical object IDs
    solver_registry_id: Option<ID>,
    protocol_treasury_id: Option<ID>,
    // Allowlists
    supported_pairs: VecSet<PairKey>,
    numeraire_pools: VecMap<TypeName, ID>,
    numeraire_type: Option<TypeName>,
    // Per-pair fee tiers (absent = Standard)
    pair_fee_tiers: VecMap<PairKey, FeeTier>,
    // Fee vaults: TypeName -> vault ID
    fee_vaults: VecMap<TypeName, ID>,
    acl: ACL,
}

fun init(ctx: &mut TxContext) {
    let admin = AdminCap { id: object::new(ctx) };
    let mut acl = ACL { members: table::new(ctx) };
    acl.members.add(ctx.sender(), vector[ROLE_CONFIG_ADMIN]);
    transfer::share_object(GlobalConfig {
        id: object::new(ctx),
        version: 5,
        collection_duration_ms: DEFAULT_COLLECTION_MS,
        bid_duration_ms: DEFAULT_BID_MS,
        selection_duration_ms: DEFAULT_SELECTION_MS,
        settlement_deadline_ms: DEFAULT_SETTLEMENT_DEADLINE_MS,
        min_batch_collect_ms: DEFAULT_MIN_BATCH_COLLECT_MS,
        standard_volume_fee_ppm: DEFAULT_STANDARD_VOLUME_FEE_PPM,
        correlated_volume_fee_ppm: DEFAULT_CORRELATED_VOLUME_FEE_PPM,
        surplus_fee_ppm: DEFAULT_SURPLUS_FEE_PPM,
        surplus_fee_cap_ppm: DEFAULT_SURPLUS_FEE_CAP_PPM,
        max_total_fee_ppm: DEFAULT_MAX_TOTAL_FEE_PPM,
        solver_reward_fee_share_ppm: DEFAULT_SOLVER_REWARD_SHARE_PPM,
        max_ucp_rounding_loss: DEFAULT_MAX_UCP_ROUNDING_LOSS,
        min_solver_stake: DEFAULT_MIN_SOLVER_STAKE,
        grief_factor_bps: DEFAULT_GRIEF_FACTOR_BPS,
        required_allocation_stake: DEFAULT_ALLOCATION_STAKE,
        required_benchmark_stake: DEFAULT_BENCHMARK_STAKE,
        fallback_bounty_bps: DEFAULT_FALLBACK_BOUNTY_BPS,
        max_allocation_bids: DEFAULT_MAX_ALLOCATION_BIDS,
        max_allocation_intents: DEFAULT_MAX_ALLOCATION_INTENTS,
        max_allocation_pairs: DEFAULT_MAX_ALLOCATION_PAIRS,
        max_slippage_tolerance_bps: DEFAULT_MAX_SLIPPAGE_BPS,
        min_sbbo_mid_price: DEFAULT_MIN_SBBO_MID_PRICE,
        price_oracle_max_age_ms: DEFAULT_PRICE_ORACLE_MAX_AGE_MS,
        solver_registry_id: option::none(),
        protocol_treasury_id: option::none(),
        supported_pairs: vec_set::empty(),
        numeraire_pools: vec_map::empty(),
        numeraire_type: option::none(),
        pair_fee_tiers: vec_map::empty(),
        fee_vaults: vec_map::empty(),
        acl,
    });
    transfer::public_transfer(admin, ctx.sender());
}

// === ACL ===

public fun has_role(config: &GlobalConfig, member: address, role: u64): bool {
    if (!config.acl.members.contains(member)) return false;
    config.acl.members.borrow(member).contains(&role)
}

public fun assert_config_admin(config: &GlobalConfig, member: address) {
    assert!(has_role(config, member, ROLE_CONFIG_ADMIN), ENotAdmin);
}

public fun grant_role(config: &mut GlobalConfig, member: address, role: u64, _cap: &AdminCap) {
    if (!config.acl.members.contains(member)) {
        config.acl.members.add(member, vector[role]);
    } else {
        let roles = config.acl.members.borrow_mut(member);
        if (!roles.contains(&role)) roles.push_back(role);
    };
    events::emit_role_granted(member, role);
}

public fun revoke_role(config: &mut GlobalConfig, member: address, role: u64, _cap: &AdminCap) {
    if (config.acl.members.contains(member)) {
        let roles = config.acl.members.borrow_mut(member);
        let (found, idx) = roles.index_of(&role);
        if (found) { roles.remove(idx); };
    };
    events::emit_role_revoked(member, role);
}

public fun role_config_admin(): u64 { ROLE_CONFIG_ADMIN }

// === Setters ===

fun set(field: &mut u64, v: u64, key: vector<u8>) {
    let old = *field;
    *field = v;
    events::emit_config_updated(key, old, v);
}

public fun set_collection_duration(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.collection_duration_ms, v, b"collection_duration_ms");
}

public fun set_bid_duration(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.bid_duration_ms, v, b"bid_duration_ms");
}

public fun set_selection_duration(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.selection_duration_ms, v, b"selection_duration_ms");
}

public fun set_settlement_deadline(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.settlement_deadline_ms, v, b"settlement_deadline_ms");
}

public fun set_min_batch_collect(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.min_batch_collect_ms, v, b"min_batch_collect_ms");
}

public fun set_standard_volume_fee_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_VOLUME_FEE_PPM && v <= c.max_total_fee_ppm, EInvalidParam);
    set(&mut c.standard_volume_fee_ppm, v, b"standard_volume_fee_ppm");
}

public fun set_correlated_volume_fee_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_VOLUME_FEE_PPM && v <= c.max_total_fee_ppm, EInvalidParam);
    set(&mut c.correlated_volume_fee_ppm, v, b"correlated_volume_fee_ppm");
}

public fun set_surplus_fee_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_SURPLUS_FEE_PPM, EInvalidParam);
    set(&mut c.surplus_fee_ppm, v, b"surplus_fee_ppm");
}

public fun set_surplus_fee_cap_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_SURPLUS_FEE_CAP_PPM, EInvalidParam);
    set(&mut c.surplus_fee_cap_ppm, v, b"surplus_fee_cap_ppm");
}

public fun set_max_total_fee_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_TOTAL_FEE_PPM, EInvalidParam);
    assert!(v >= c.standard_volume_fee_ppm && v >= c.correlated_volume_fee_ppm, EInvalidParam);
    set(&mut c.max_total_fee_ppm, v, b"max_total_fee_ppm");
}

public fun set_solver_reward_share_ppm(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_SOLVER_REWARD_SHARE_PPM, EInvalidParam);
    set(&mut c.solver_reward_fee_share_ppm, v, b"solver_reward_fee_share_ppm");
}

public fun set_max_ucp_rounding_loss(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.max_ucp_rounding_loss, v, b"max_ucp_rounding_loss");
}

public fun set_min_solver_stake(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.min_solver_stake, v, b"min_solver_stake");
}

public fun set_grief_factor(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v >= MIN_GRIEF_FACTOR_BPS, EInvalidParam);
    set(&mut c.grief_factor_bps, v, b"grief_factor_bps");
}

public fun set_required_allocation_stake(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.required_allocation_stake, v, b"required_allocation_stake");
}

public fun set_required_benchmark_stake(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.required_benchmark_stake, v, b"required_benchmark_stake");
}

public fun set_fallback_bounty_bps(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_FALLBACK_BOUNTY_BPS, EInvalidParam);
    set(&mut c.fallback_bounty_bps, v, b"fallback_bounty_bps");
}

public fun set_max_allocation_bids(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.max_allocation_bids, v, b"max_allocation_bids");
}

public fun set_max_allocation_intents(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.max_allocation_intents, v, b"max_allocation_intents");
}

public fun set_max_allocation_pairs(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.max_allocation_pairs, v, b"max_allocation_pairs");
}

public fun set_max_slippage(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0 && v <= MAX_SLIPPAGE_BPS, EInvalidParam);
    set(&mut c.max_slippage_tolerance_bps, v, b"max_slippage_tolerance_bps");
}

public fun set_min_sbbo_mid_price(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.min_sbbo_mid_price, v, b"min_sbbo_mid_price");
}

public fun set_price_oracle_max_age(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.price_oracle_max_age_ms, v, b"price_oracle_max_age_ms");
}

// === Pair fee tiers ===

public fun set_pair_fee_tier<Sell, Buy>(
    c: &mut GlobalConfig,
    tier: FeeTier,
    _: &AdminCap,
) {
    let key = types::pair_key<Sell, Buy>();
    if (c.pair_fee_tiers.contains(&key)) {
        *c.pair_fee_tiers.get_mut(&key) = tier;
    } else {
        c.pair_fee_tiers.insert(key, tier);
    };
}

public fun pair_fee_tier(c: &GlobalConfig, key: &PairKey): FeeTier {
    if (c.pair_fee_tiers.contains(key)) *c.pair_fee_tiers.get(key)
    else FeeTier::Standard
}

/// Returns volume_fee_ppm for the pair's tier.
public fun volume_fee_ppm_for_pair(c: &GlobalConfig, key: &PairKey): u64 {
    match (pair_fee_tier(c, key)) {
        FeeTier::Standard => c.standard_volume_fee_ppm,
        FeeTier::Correlated => c.correlated_volume_fee_ppm,
        FeeTier::Custom(ppm) => ppm,
        FeeTier::Disabled => 0,
    }
}

// === Fee vault registry ===

public fun register_fee_vault<T>(c: &mut GlobalConfig, vault_id: ID, _: &AdminCap) {
    let key = type_name::with_defining_ids<T>();
    if (c.fee_vaults.contains(&key)) {
        *c.fee_vaults.get_mut(&key) = vault_id;
    } else {
        c.fee_vaults.insert(key, vault_id);
    };
    events::emit_fee_vault_registered(key, vault_id);
}

public fun fee_vault_id<T>(c: &GlobalConfig): ID {
    let key = type_name::with_defining_ids<T>();
    assert!(c.fee_vaults.contains(&key), EFeeVaultNotRegistered);
    *c.fee_vaults.get(&key)
}

public fun assert_fee_vault_id<T>(c: &GlobalConfig, id: ID) {
    assert!(fee_vault_id<T>(c) == id, EWrongCanonicalObject);
}

// === Allowlists ===

public fun add_supported_pair<Sell, Buy>(c: &mut GlobalConfig, _: &AdminCap) {
    let key = types::pair_key<Sell, Buy>();
    if (!c.supported_pairs.contains(&key)) c.supported_pairs.insert(key);
}

public fun remove_supported_pair<Sell, Buy>(c: &mut GlobalConfig, _: &AdminCap) {
    let key = types::pair_key<Sell, Buy>();
    if (c.supported_pairs.contains(&key)) c.supported_pairs.remove(&key);
}

public fun is_pair_supported(c: &GlobalConfig, key: &PairKey): bool {
    c.supported_pairs.contains(key)
}

public fun assert_pair_supported(c: &GlobalConfig, key: &PairKey) {
    assert!(c.supported_pairs.contains(key), EPairNotSupported);
}

public fun set_numeraire<N>(c: &mut GlobalConfig, _: &AdminCap) {
    c.numeraire_type = option::some(type_name::with_defining_ids<N>());
}

public fun add_numeraire_pool<Token>(c: &mut GlobalConfig, pool_id: ID, _: &AdminCap) {
    let key = type_name::with_defining_ids<Token>();
    if (c.numeraire_pools.contains(&key)) {
        *c.numeraire_pools.get_mut(&key) = pool_id;
    } else {
        c.numeraire_pools.insert(key, pool_id);
    };
}

public fun remove_numeraire_pool<Token>(c: &mut GlobalConfig, _: &AdminCap) {
    let key = type_name::with_defining_ids<Token>();
    if (c.numeraire_pools.contains(&key)) { c.numeraire_pools.remove(&key); };
}

public fun numeraire_pool_id(c: &GlobalConfig, token: TypeName): Option<ID> {
    if (c.numeraire_pools.contains(&token)) option::some(*c.numeraire_pools.get(&token))
    else option::none()
}

public fun numeraire_type(c: &GlobalConfig): TypeName {
    assert!(c.numeraire_type.is_some(), ENumeraireNotSet);
    *c.numeraire_type.borrow()
}

public fun set_solver_registry_id(c: &mut GlobalConfig, id: ID, _: &AdminCap) {
    if (c.solver_registry_id.is_some()) {
        assert!(*c.solver_registry_id.borrow() == id, ECanonicalObjectAlreadySet);
    } else {
        c.solver_registry_id = option::some(id);
    };
}

public fun set_protocol_treasury_id(c: &mut GlobalConfig, id: ID, _: &AdminCap) {
    if (c.protocol_treasury_id.is_some()) {
        assert!(*c.protocol_treasury_id.borrow() == id, ECanonicalObjectAlreadySet);
    } else {
        c.protocol_treasury_id = option::some(id);
    };
}

public fun assert_solver_registry_id(c: &GlobalConfig, id: ID) {
    assert!(c.solver_registry_id.is_some(), ECanonicalObjectNotSet);
    assert!(*c.solver_registry_id.borrow() == id, EWrongCanonicalObject);
}

public fun assert_protocol_treasury_id(c: &GlobalConfig, id: ID) {
    assert!(c.protocol_treasury_id.is_some(), ECanonicalObjectNotSet);
    assert!(*c.protocol_treasury_id.borrow() == id, EWrongCanonicalObject);
}

// === Getters ===

public fun version(c: &GlobalConfig): u64 { c.version }

public fun collection_duration_ms(c: &GlobalConfig): u64 { c.collection_duration_ms }

public fun bid_duration_ms(c: &GlobalConfig): u64 { c.bid_duration_ms }

public fun selection_duration_ms(c: &GlobalConfig): u64 { c.selection_duration_ms }

public fun settlement_deadline_ms(c: &GlobalConfig): u64 { c.settlement_deadline_ms }

public fun min_batch_collect_ms(c: &GlobalConfig): u64 { c.min_batch_collect_ms }

public fun standard_volume_fee_ppm(c: &GlobalConfig): u64 { c.standard_volume_fee_ppm }

public fun correlated_volume_fee_ppm(c: &GlobalConfig): u64 { c.correlated_volume_fee_ppm }

public fun surplus_fee_ppm(c: &GlobalConfig): u64 { c.surplus_fee_ppm }

public fun surplus_fee_cap_ppm(c: &GlobalConfig): u64 { c.surplus_fee_cap_ppm }

public fun max_total_fee_ppm(c: &GlobalConfig): u64 { c.max_total_fee_ppm }

public fun solver_reward_fee_share_ppm(c: &GlobalConfig): u64 { c.solver_reward_fee_share_ppm }

public fun max_ucp_rounding_loss(c: &GlobalConfig): u64 { c.max_ucp_rounding_loss }

public fun min_solver_stake(c: &GlobalConfig): u64 { c.min_solver_stake }

public fun grief_factor_bps(c: &GlobalConfig): u64 { c.grief_factor_bps }

public fun required_allocation_stake(c: &GlobalConfig): u64 { c.required_allocation_stake }

public fun required_benchmark_stake(c: &GlobalConfig): u64 { c.required_benchmark_stake }

public fun fallback_bounty_bps(c: &GlobalConfig): u64 { c.fallback_bounty_bps }

public fun max_allocation_bids(c: &GlobalConfig): u64 { c.max_allocation_bids }

public fun max_allocation_intents(c: &GlobalConfig): u64 { c.max_allocation_intents }

public fun max_allocation_pairs(c: &GlobalConfig): u64 { c.max_allocation_pairs }

public fun solver_registry_id(c: &GlobalConfig): ID {
    assert!(c.solver_registry_id.is_some(), ECanonicalObjectNotSet);
    *c.solver_registry_id.borrow()
}

public fun protocol_treasury_id(c: &GlobalConfig): ID {
    assert!(c.protocol_treasury_id.is_some(), ECanonicalObjectNotSet);
    *c.protocol_treasury_id.borrow()
}

public fun max_slippage_tolerance_bps(c: &GlobalConfig): u64 { c.max_slippage_tolerance_bps }

public fun min_sbbo_mid_price(c: &GlobalConfig): u64 { c.min_sbbo_mid_price }

public fun price_oracle_max_age_ms(c: &GlobalConfig): u64 { c.price_oracle_max_age_ms }

// === FeeTier constructors (public so external callers can pass tier values) ===

public fun fee_tier_standard(): FeeTier { FeeTier::Standard }
public fun fee_tier_correlated(): FeeTier { FeeTier::Correlated }
public fun fee_tier_disabled(): FeeTier { FeeTier::Disabled }
public fun fee_tier_custom(ppm: u64): FeeTier { FeeTier::Custom(ppm) }

// === Test-only ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
