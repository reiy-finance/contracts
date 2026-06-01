// Copyright (c) Reiy Finance

/// Solver registration, stake reservation, and slashing.
module reiy::solver_registry;

use reiy::config::{GlobalConfig, AdminCap};
use reiy::events;
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};

const REASON_TIMEOUT: u8 = 0;
const SUSPEND_THRESHOLD: u64 = 3;
const KIND_BID: u8 = 0;
const KIND_ALLOCATION: u8 = 1;
const KIND_BENCHMARK: u8 = 2;

#[error]
const ESolverAlreadyRegistered: vector<u8> = b"solver already registered";
#[error]
const ESolverNotRegistered: vector<u8> = b"solver not registered";
#[error]
const ESolverNotActive: vector<u8> = b"solver not active";
#[error]
const EStakeTooSmall: vector<u8> = b"stake below required amount";
#[error]
const EInsufficientStake: vector<u8> = b"stake operation exceeds available amount";
#[error]
const EReservationExists: vector<u8> = b"stake reservation already exists";
#[error]
const EReservationMissing: vector<u8> = b"stake reservation missing";
#[error]
const EReservedStakeOutstanding: vector<u8> = b"reserved stake outstanding";

public enum SolverStatus has copy, drop, store {
    Active,
    Suspended,
    Deregistered,
}

public struct StakeReservationKey has copy, drop, store {
    kind: u8,
    epoch: u64,
    seq: u64,
}

/// Per-solver metadata stored inside `SolverRegistry`.
/// * `url`            - Off-chain endpoint URL of the solver service
/// * `total_settled`  - Cumulative buy-token volume settled by this solver (audit metric)
/// * `slash_count`    - Number of slash events; auto-suspends at `SUSPEND_THRESHOLD`
/// * `status`         - Current activity status of the solver
/// * `reserved_stake` - Total stake currently reserved for open obligations
public struct SolverInfo has store {
    url: vector<u8>,
    total_settled: u64,
    slash_count: u64,
    status: SolverStatus,
    reserved_stake: u64,
}

public struct StakeReservation has copy, drop, store {
    owner: address,
    amount: u64,
}

/// Shared registry of all registered solvers and their generic stake balances.
public struct SolverRegistry<phantom Stake> has key {
    id: UID,
    solvers: Table<address, SolverInfo>,
    stakes: Table<address, Balance<Stake>>,
    reservations: Table<StakeReservationKey, StakeReservation>,
    slash_history: Table<address, u64>,
}

public fun init_registry<Stake>(_cap: &AdminCap, ctx: &mut TxContext): ID {
    let registry = SolverRegistry<Stake> {
        id: object::new(ctx),
        solvers: table::new(ctx),
        stakes: table::new(ctx),
        reservations: table::new(ctx),
        slash_history: table::new(ctx),
    };
    let id = object::id(&registry);
    transfer::share_object(registry);
    id
}

public fun register_solver<Stake>(
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    stake: Coin<Stake>,
    url: vector<u8>,
    ctx: &TxContext,
) {
    let solver = ctx.sender();
    assert!(!registry.solvers.contains(solver), ESolverAlreadyRegistered);
    assert!(stake.value() >= config.min_solver_stake(), EStakeTooSmall);
    let amount = stake.value();
    let slash_count = if (registry.slash_history.contains(solver)) {
        *registry.slash_history.borrow(solver)
    } else {
        0
    };
    let status = if (slash_count >= SUSPEND_THRESHOLD) {
        SolverStatus::Suspended
    } else {
        SolverStatus::Active
    };
    registry
        .solvers
        .add(
            solver,
            SolverInfo {
                url,
                total_settled: 0,
                slash_count,
                status,
                reserved_stake: 0,
            },
        );
    registry.stakes.add(solver, stake.into_balance());
    events::emit_solver_registered(solver, amount);
}

public fun top_up_stake<Stake>(
    registry: &mut SolverRegistry<Stake>,
    stake: Coin<Stake>,
    ctx: &TxContext,
) {
    let solver = ctx.sender();
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.stakes.borrow_mut(solver).join(stake.into_balance());
}

public fun withdraw_available_stake<Stake>(
    registry: &mut SolverRegistry<Stake>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Stake> {
    let solver = ctx.sender();
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    assert!(amount <= available_stake_of(registry, solver), EInsufficientStake);
    coin::take(registry.stakes.borrow_mut(solver), amount, ctx)
}

public fun deregister_solver<Stake>(
    registry: &mut SolverRegistry<Stake>,
    ctx: &mut TxContext,
): Coin<Stake> {
    let solver = ctx.sender();
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    assert!(reserved_stake_of(registry, solver) == 0, EReservedStakeOutstanding);
    let SolverInfo { .. } = registry.solvers.remove(solver);
    let stake = registry.stakes.remove(solver);
    let amount = stake.value();
    events::emit_solver_deregistered(solver, amount);
    coin::from_balance(stake, ctx)
}

public fun reactivate_solver<Stake>(
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    solver: address,
    _cap: &AdminCap,
) {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    assert!(stake_of(registry, solver) >= config.min_solver_stake(), EStakeTooSmall);
    registry.solvers.borrow_mut(solver).status = SolverStatus::Active;
}

public(package) fun reserve_stake<Stake>(
    registry: &mut SolverRegistry<Stake>,
    config: &GlobalConfig,
    owner: address,
    key: StakeReservationKey,
    amount: u64,
) {
    assert!(is_active(registry, config, owner), ESolverNotActive);
    assert!(!registry.reservations.contains(key), EReservationExists);
    assert!(available_stake_of(registry, owner) >= amount, EInsufficientStake);
    registry.reservations.add(key, StakeReservation { owner, amount });
    registry.solvers.borrow_mut(owner).reserved_stake =
        registry.solvers.borrow(owner).reserved_stake + amount;
}

public(package) fun release_stake<Stake>(
    registry: &mut SolverRegistry<Stake>,
    key: StakeReservationKey,
) {
    if (!registry.reservations.contains(key)) return;
    let StakeReservation { owner, amount } = registry.reservations.remove(key);
    let info = registry.solvers.borrow_mut(owner);
    assert!(amount <= info.reserved_stake, EInsufficientStake);
    info.reserved_stake = info.reserved_stake - amount;
}

public(package) fun slash_reserved_stake<Stake>(
    registry: &mut SolverRegistry<Stake>,
    key: StakeReservationKey,
    reason: u8,
    _ctx: &TxContext,
): Balance<Stake> {
    assert!(registry.reservations.contains(key), EReservationMissing);
    let StakeReservation { owner, amount } = registry.reservations.remove(key);
    assert!(registry.solvers.contains(owner), ESolverNotRegistered);
    let info = registry.solvers.borrow_mut(owner);
    assert!(amount <= info.reserved_stake, EInsufficientStake);
    info.reserved_stake = info.reserved_stake - amount;
    info.slash_count = info.slash_count + 1;
    if (registry.slash_history.contains(owner)) {
        *registry.slash_history.borrow_mut(owner) = info.slash_count;
    } else {
        registry.slash_history.add(owner, info.slash_count);
    };
    if (info.slash_count >= SUSPEND_THRESHOLD) { info.status = SolverStatus::Suspended; };

    let stake = registry.stakes.borrow_mut(owner);
    assert!(amount <= stake.value(), EInsufficientStake);
    let slashed = stake.split(amount);
    events::emit_solver_slashed(owner, amount, reason);
    slashed
}

public(package) fun record_settled<Stake>(
    registry: &mut SolverRegistry<Stake>,
    solver: address,
    amount: u64,
) {
    if (registry.solvers.contains(solver)) {
        registry.solvers.borrow_mut(solver).total_settled =
            registry.solvers.borrow(solver).total_settled + amount;
    };
}

public fun is_registered<Stake>(registry: &SolverRegistry<Stake>, solver: address): bool {
    registry.solvers.contains(solver)
}

public fun id<Stake>(registry: &SolverRegistry<Stake>): ID { object::id(registry) }

public fun is_active<Stake>(
    registry: &SolverRegistry<Stake>,
    config: &GlobalConfig,
    solver: address,
): bool {
    if (!registry.solvers.contains(solver)) return false;
    if (stake_of(registry, solver) < config.min_solver_stake()) return false;
    match (registry.solvers.borrow(solver).status) {
        SolverStatus::Active => true,
        _ => false,
    }
}

public fun stake_of<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    if (!registry.stakes.contains(solver)) return 0;
    registry.stakes.borrow(solver).value()
}

public fun reserved_stake_of<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    if (!registry.solvers.contains(solver)) return 0;
    registry.solvers.borrow(solver).reserved_stake
}

public fun available_stake_of<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    let stake = stake_of(registry, solver);
    let reserved = reserved_stake_of(registry, solver);
    if (stake > reserved) stake - reserved else 0
}

public fun reservation_amount<Stake>(
    registry: &SolverRegistry<Stake>,
    key: StakeReservationKey,
): u64 {
    if (!registry.reservations.contains(key)) return 0;
    registry.reservations.borrow(key).amount
}

public fun reservation_owner<Stake>(
    registry: &SolverRegistry<Stake>,
    key: StakeReservationKey,
): address {
    assert!(registry.reservations.contains(key), EReservationMissing);
    registry.reservations.borrow(key).owner
}

public fun has_reservation<Stake>(
    registry: &SolverRegistry<Stake>,
    key: StakeReservationKey,
): bool {
    registry.reservations.contains(key)
}

public fun slash_count<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).slash_count
}

public fun total_settled<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).total_settled
}

public fun reason_timeout(): u8 { REASON_TIMEOUT }

public fun reservation_kind_bid(): u8 { KIND_BID }

public fun reservation_kind_allocation(): u8 { KIND_ALLOCATION }

public fun reservation_kind_benchmark(): u8 { KIND_BENCHMARK }

public fun reservation_key(kind: u8, epoch: u64, seq: u64): StakeReservationKey {
    StakeReservationKey { kind, epoch, seq }
}

public fun bid_reservation_key(epoch: u64, seq: u64): StakeReservationKey {
    reservation_key(KIND_BID, epoch, seq)
}

public fun allocation_reservation_key(epoch: u64, seq: u64): StakeReservationKey {
    reservation_key(KIND_ALLOCATION, epoch, seq)
}

public fun benchmark_reservation_key(epoch: u64, seq: u64): StakeReservationKey {
    reservation_key(KIND_BENCHMARK, epoch, seq)
}

public fun assert_registered<Stake>(registry: &SolverRegistry<Stake>, solver: address) {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
}

#[test_only]
public fun init_for_testing<Stake>(cap: &AdminCap, ctx: &mut TxContext): ID {
    init_registry<Stake>(cap, ctx)
}
