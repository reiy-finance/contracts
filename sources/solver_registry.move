// Copyright (c) Reiy Finance

/// Solver registration, bond management, and slashing.
module reiy::solver_registry;

use reiy::config::GlobalConfig;
use reiy::events;
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::table::{Self, Table};

const REASON_TIMEOUT: u8 = 0;
const SUSPEND_THRESHOLD: u64 = 3;

#[error]
const ESolverAlreadyRegistered: vector<u8> = b"solver already registered";
#[error]
const ESolverNotRegistered: vector<u8> = b"solver not registered";
#[error]
const EBondTooSmall: vector<u8> = b"bond below configured minimum";
#[error]
const EInsufficientBond: vector<u8> = b"slash/withdraw exceeds available bond";

public enum SolverStatus has copy, drop, store {
    Active,
    Suspended,
    Deregistered,
}

/// Per-solver metadata stored inside `SolverRegistry`.
/// * `url`            - Off-chain endpoint URL of the solver service
/// * `total_settled`  - Cumulative buy-token volume settled by this solver (audit metric)
/// * `slash_count`    - Number of slash events; auto-suspends at `SUSPEND_THRESHOLD`
/// * `status`         - Current activity status of the solver
public struct SolverInfo has store {
    url: vector<u8>,
    total_settled: u64,
    slash_count: u64,
    status: SolverStatus,
}

/// Shared registry of all registered solvers and their SUI bonds.
/// * `id`      - UID of the shared object
/// * `solvers` - Map from solver address to solver metadata
/// * `bonds`   - Map from solver address to locked SUI bond balance
public struct SolverRegistry has key {
    id: UID,
    solvers: Table<address, SolverInfo>,
    bonds: Table<address, Balance<SUI>>,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(SolverRegistry {
        id: object::new(ctx),
        solvers: table::new(ctx),
        bonds: table::new(ctx),
    });
}

public fun register_solver(
    registry: &mut SolverRegistry,
    config: &GlobalConfig,
    bond: Coin<SUI>,
    url: vector<u8>,
    ctx: &TxContext,
) {
    let solver = ctx.sender();
    assert!(!registry.solvers.contains(solver), ESolverAlreadyRegistered);
    assert!(bond.value() >= config.min_bid_bond(), EBondTooSmall);
    let amount = bond.value();
    registry
        .solvers
        .add(
            solver,
            SolverInfo { url, total_settled: 0, slash_count: 0, status: SolverStatus::Active },
        );
    registry.bonds.add(solver, bond.into_balance());
    events::emit_solver_registered(solver, amount);
}

/// Top up bond to cover `score * grief_factor` for larger bids.
public fun top_up_bond(registry: &mut SolverRegistry, bond: Coin<SUI>, ctx: &TxContext) {
    let solver = ctx.sender();
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.bonds.borrow_mut(solver).join(bond.into_balance());
}

/// Remove solver and return full bond. Phase gating is the caller's responsibility.
public(package) fun deregister_internal(
    registry: &mut SolverRegistry,
    solver: address,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    let SolverInfo { .. } = registry.solvers.remove(solver);
    let bond = registry.bonds.remove(solver);
    let amount = bond.value();
    events::emit_solver_deregistered(solver, amount);
    coin::from_balance(bond, ctx)
}

/// Slash `amount` from bond; auto-suspends at `SUSPEND_THRESHOLD` slashes.
public(package) fun slash(
    registry: &mut SolverRegistry,
    solver: address,
    amount: u64,
    reason: u8,
    _ctx: &TxContext,
): Balance<SUI> {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    let b = registry.bonds.borrow_mut(solver);
    assert!(amount <= b.value(), EInsufficientBond);
    let slashed = b.split(amount);
    let info = registry.solvers.borrow_mut(solver);
    info.slash_count = info.slash_count + 1;
    if (info.slash_count >= SUSPEND_THRESHOLD) { info.status = SolverStatus::Suspended; };
    events::emit_solver_slashed(solver, amount, reason);
    slashed
}

public(package) fun record_settled(registry: &mut SolverRegistry, solver: address, amount: u64) {
    if (registry.solvers.contains(solver)) {
        registry.solvers.borrow_mut(solver).total_settled =
            registry.solvers.borrow(solver).total_settled + amount;
    };
}

public fun is_registered(registry: &SolverRegistry, solver: address): bool {
    registry.solvers.contains(solver)
}

public fun is_active(registry: &SolverRegistry, solver: address): bool {
    if (!registry.solvers.contains(solver)) return false;
    match (registry.solvers.borrow(solver).status) {
        SolverStatus::Active => true,
        _ => false,
    }
}

public fun bond_of(registry: &SolverRegistry, solver: address): u64 {
    if (!registry.bonds.contains(solver)) return 0;
    registry.bonds.borrow(solver).value()
}

public fun slash_count(registry: &SolverRegistry, solver: address): u64 {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).slash_count
}

public fun total_settled(registry: &SolverRegistry, solver: address): u64 {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).total_settled
}

public fun reason_timeout(): u8 { REASON_TIMEOUT }

public fun assert_registered(registry: &SolverRegistry, solver: address) {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
