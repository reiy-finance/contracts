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
const MAX_FEE_BPS: u64 = 1_000;
const MAX_SLIPPAGE_BPS: u64 = 2_000;
const MAX_BPS: u64 = 10_000;
const MIN_GRIEF_FACTOR_BPS: u64 = 10_000; // bond >= 1.0x griefed score

const DEFAULT_COLLECTION_MS: u64 = 10_000;
const DEFAULT_BID_MS: u64 = 5_000;
const DEFAULT_SELECTION_MS: u64 = 5_000;
const DEFAULT_SETTLEMENT_DEADLINE_MS: u64 = 30_000;
const DEFAULT_MIN_BATCH_COLLECT_MS: u64 = 10_000;
const DEFAULT_FEE_BPS: u64 = 5;
const DEFAULT_MIN_BID_BOND: u64 = 1_000_000_000;
const DEFAULT_GRIEF_FACTOR_BPS: u64 = 15_000;
const DEFAULT_ALLOCATION_BOND: u64 = 1_000_000_000;
const DEFAULT_REWARD_SHARE_BPS: u64 = 2_000;
const DEFAULT_REWARD_CAP_BPS: u64 = 100;
const DEFAULT_AUCTIONEER_SHARE_BPS: u64 = 500;
const DEFAULT_AUCTIONEER_REWARD_CAP: u64 = 1_000_000_000;
const DEFAULT_MAX_SLIPPAGE_BPS: u64 = 500;
const DEFAULT_MIN_SBBO_MID_PRICE: u64 = 1;
const DEFAULT_PRICE_ORACLE_MAX_AGE_MS: u64 = 60_000;
const DEFAULT_EPSR_TOLERANCE_BPS: u64 = 5;
const DEFAULT_K_TOLERANCE_BPS: u64 = 9_500;
const DEFAULT_SCORE_TOLERANCE_BPS: u64 = 9_500;

#[error]
const ENotAdmin: vector<u8> = b"caller lacks ROLE_CONFIG_ADMIN";
#[error]
const EInvalidParam: vector<u8> = b"parameter out of allowed bounds";
#[error]
const ENumeraireNotSet: vector<u8> = b"numeraire type not configured";
#[error]
const EPairNotSupported: vector<u8> = b"directed pair not on allowlist";

/// Owned capability gating all mutations.
public struct AdminCap has key, store { id: UID }

public struct ACL has store {
    members: Table<address, vector<u64>>,
}

/// Shared protocol configuration object. All mutations require `AdminCap`.
/// * `id`                          - UID of the shared object
/// * `version`                     - Schema version; bumped on breaking field changes
/// * `collection_duration_ms`      - Duration of the IntentCollection phase (ms)
/// * `bid_duration_ms`             - Duration of the Bid phase (ms)
/// * `selection_duration_ms`       - Duration of the AllocationSelection phase (ms)
/// * `settlement_deadline_ms`      - Maximum time allowed for settlement after winner selection (ms)
/// * `min_batch_collect_ms`        - Minimum cooldown between epochs (ms)
/// * `protocol_fee_bps`            - Protocol fee charged on settled volume (bps)
/// * `min_bid_bond`                - Minimum SUI bond required to register as a solver
/// * `grief_factor_bps`            - Bond scaling factor; required bond = max(min, score * grief_factor)
/// * `required_allocation_bond`    - Bond required to submit an Allocation
/// * `reward_share_bps`            - Solver reward as a fraction of verified surplus (bps)
/// * `reward_cap_bps`              - Hard cap on total solver reward as a fraction of settled value (bps)
/// * `auctioneer_share_bps`        - Auctioneer reward share (bps)
/// * `auctioneer_reward_cap`       - Hard cap on auctioneer reward (absolute, in numeraire)
/// * `max_slippage_tolerance_bps`  - Maximum allowed slippage tolerance per intent submission (bps)
/// * `min_sbbo_mid_price`          - Minimum acceptable DeepBook mid price; zero price is rejected
/// * `price_oracle_max_age_ms`     - Maximum acceptable age of a price observation (ms)
/// * `epsr_tolerance_bps`          - Per-intent EPSR cross-multiplication tolerance (bps)
/// * `k_tolerance_bps`             - Batch-level tolerance for actual k vs committed k (bps)
/// * `score_tolerance_bps`         - Batch-level tolerance for actual score vs committed score (bps)
/// * `supported_pairs`             - Allowlist of directed pairs accepted for intent submission
/// * `numeraire_pools`             - Map from buy-token type to its DeepBook numeraire pool ID
/// * `numeraire_type`              - The protocol numeraire token type (e.g. USDC)
/// * `acl`                         - Role-based access control table
public struct GlobalConfig has key {
    id: UID,
    version: u64,
    collection_duration_ms: u64,
    bid_duration_ms: u64,
    selection_duration_ms: u64,
    settlement_deadline_ms: u64,
    min_batch_collect_ms: u64,
    protocol_fee_bps: u64,
    min_bid_bond: u64,
    grief_factor_bps: u64,
    required_allocation_bond: u64,
    reward_share_bps: u64,
    reward_cap_bps: u64,
    auctioneer_share_bps: u64,
    auctioneer_reward_cap: u64,
    max_slippage_tolerance_bps: u64,
    min_sbbo_mid_price: u64,
    price_oracle_max_age_ms: u64,
    epsr_tolerance_bps: u64,
    k_tolerance_bps: u64,
    score_tolerance_bps: u64,
    supported_pairs: VecSet<PairKey>,
    numeraire_pools: VecMap<TypeName, ID>,
    numeraire_type: Option<TypeName>,
    acl: ACL,
}

fun init(ctx: &mut TxContext) {
    let admin = AdminCap { id: object::new(ctx) };
    let mut acl = ACL { members: table::new(ctx) };
    acl.members.add(ctx.sender(), vector[ROLE_CONFIG_ADMIN]);
    transfer::share_object(GlobalConfig {
        id: object::new(ctx),
        version: 1,
        collection_duration_ms: DEFAULT_COLLECTION_MS,
        bid_duration_ms: DEFAULT_BID_MS,
        selection_duration_ms: DEFAULT_SELECTION_MS,
        settlement_deadline_ms: DEFAULT_SETTLEMENT_DEADLINE_MS,
        min_batch_collect_ms: DEFAULT_MIN_BATCH_COLLECT_MS,
        protocol_fee_bps: DEFAULT_FEE_BPS,
        min_bid_bond: DEFAULT_MIN_BID_BOND,
        grief_factor_bps: DEFAULT_GRIEF_FACTOR_BPS,
        required_allocation_bond: DEFAULT_ALLOCATION_BOND,
        reward_share_bps: DEFAULT_REWARD_SHARE_BPS,
        reward_cap_bps: DEFAULT_REWARD_CAP_BPS,
        auctioneer_share_bps: DEFAULT_AUCTIONEER_SHARE_BPS,
        auctioneer_reward_cap: DEFAULT_AUCTIONEER_REWARD_CAP,
        max_slippage_tolerance_bps: DEFAULT_MAX_SLIPPAGE_BPS,
        min_sbbo_mid_price: DEFAULT_MIN_SBBO_MID_PRICE,
        price_oracle_max_age_ms: DEFAULT_PRICE_ORACLE_MAX_AGE_MS,
        epsr_tolerance_bps: DEFAULT_EPSR_TOLERANCE_BPS,
        k_tolerance_bps: DEFAULT_K_TOLERANCE_BPS,
        score_tolerance_bps: DEFAULT_SCORE_TOLERANCE_BPS,
        supported_pairs: vec_set::empty(),
        numeraire_pools: vec_map::empty(),
        numeraire_type: option::none(),
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

public fun set_protocol_fee(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_FEE_BPS, EInvalidParam);
    set(&mut c.protocol_fee_bps, v, b"protocol_fee_bps");
}

public fun set_min_bid_bond(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0, EInvalidParam);
    set(&mut c.min_bid_bond, v, b"min_bid_bond");
}

public fun set_grief_factor(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v >= MIN_GRIEF_FACTOR_BPS, EInvalidParam);
    set(&mut c.grief_factor_bps, v, b"grief_factor_bps");
}

public fun set_required_allocation_bond(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.required_allocation_bond, v, b"required_allocation_bond");
}

public fun set_reward_share(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_BPS, EInvalidParam);
    set(&mut c.reward_share_bps, v, b"reward_share_bps");
}

public fun set_reward_cap(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_BPS, EInvalidParam);
    set(&mut c.reward_cap_bps, v, b"reward_cap_bps");
}

public fun set_auctioneer_share(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_BPS, EInvalidParam);
    set(&mut c.auctioneer_share_bps, v, b"auctioneer_share_bps");
}

public fun set_auctioneer_reward_cap(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    set(&mut c.auctioneer_reward_cap, v, b"auctioneer_reward_cap");
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

public fun set_epsr_tolerance(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v <= MAX_BPS, EInvalidParam);
    set(&mut c.epsr_tolerance_bps, v, b"epsr_tolerance_bps");
}

public fun set_k_tolerance(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0 && v <= MAX_BPS, EInvalidParam);
    set(&mut c.k_tolerance_bps, v, b"k_tolerance_bps");
}

public fun set_score_tolerance(c: &mut GlobalConfig, v: u64, _: &AdminCap) {
    assert!(v > 0 && v <= MAX_BPS, EInvalidParam);
    set(&mut c.score_tolerance_bps, v, b"score_tolerance_bps");
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

// === Getters ===

public fun version(c: &GlobalConfig): u64 { c.version }

public fun collection_duration_ms(c: &GlobalConfig): u64 { c.collection_duration_ms }

public fun bid_duration_ms(c: &GlobalConfig): u64 { c.bid_duration_ms }

public fun selection_duration_ms(c: &GlobalConfig): u64 { c.selection_duration_ms }

public fun settlement_deadline_ms(c: &GlobalConfig): u64 { c.settlement_deadline_ms }

public fun min_batch_collect_ms(c: &GlobalConfig): u64 { c.min_batch_collect_ms }

public fun protocol_fee_bps(c: &GlobalConfig): u64 { c.protocol_fee_bps }

public fun min_bid_bond(c: &GlobalConfig): u64 { c.min_bid_bond }

public fun grief_factor_bps(c: &GlobalConfig): u64 { c.grief_factor_bps }

public fun required_allocation_bond(c: &GlobalConfig): u64 { c.required_allocation_bond }

public fun reward_share_bps(c: &GlobalConfig): u64 { c.reward_share_bps }

public fun reward_cap_bps(c: &GlobalConfig): u64 { c.reward_cap_bps }

public fun auctioneer_share_bps(c: &GlobalConfig): u64 { c.auctioneer_share_bps }

public fun auctioneer_reward_cap(c: &GlobalConfig): u64 { c.auctioneer_reward_cap }

public fun max_slippage_tolerance_bps(c: &GlobalConfig): u64 { c.max_slippage_tolerance_bps }

public fun min_sbbo_mid_price(c: &GlobalConfig): u64 { c.min_sbbo_mid_price }

public fun price_oracle_max_age_ms(c: &GlobalConfig): u64 { c.price_oracle_max_age_ms }

public fun epsr_tolerance_bps(c: &GlobalConfig): u64 { c.epsr_tolerance_bps }

public fun k_tolerance_bps(c: &GlobalConfig): u64 { c.k_tolerance_bps }

public fun score_tolerance_bps(c: &GlobalConfig): u64 { c.score_tolerance_bps }

// === Test-only ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
