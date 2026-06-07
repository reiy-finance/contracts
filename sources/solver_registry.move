// Copyright (c) Reiy Finance

/// Solver registry for the hybrid model. Solver quote collection, ranking, retries, and any
/// operational penalties live off-chain in the Execution Coordinator; on-chain settlement only
/// checks that the signed solver is registered and still has the configured minimum stake.
module reiy::solver_registry;

use reiy::config::{AdminCap, GlobalConfig};
use reiy::events;
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::table::{Self, Table};

#[error]
const ESolverAlreadyRegistered: vector<u8> = b"solver already registered";
#[error]
const ESolverNotRegistered: vector<u8> = b"solver not registered";
#[error]
const EStakeTooSmall: vector<u8> = b"stake below required amount";
#[error]
const EInsufficientStake: vector<u8> = b"stake operation exceeds available amount";

public struct SolverInfo has store {
    url: vector<u8>,
    total_settled: u64,
}

public struct SolverRegistry<phantom Stake> has key {
    id: UID,
    solvers: Table<address, SolverInfo>,
    stakes: Table<address, Balance<Stake>>,
}

public fun init_registry<Stake>(_cap: &AdminCap, ctx: &mut TxContext): ID {
    let registry = SolverRegistry<Stake> {
        id: object::new(ctx),
        solvers: table::new(ctx),
        stakes: table::new(ctx),
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
    registry.solvers.add(solver, SolverInfo { url, total_settled: 0 });
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
    assert!(amount <= stake_of(registry, solver), EInsufficientStake);
    coin::take(registry.stakes.borrow_mut(solver), amount, ctx)
}

public fun deregister_solver<Stake>(
    registry: &mut SolverRegistry<Stake>,
    ctx: &mut TxContext,
): Coin<Stake> {
    let solver = ctx.sender();
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    let SolverInfo { .. } = registry.solvers.remove(solver);
    let stake = registry.stakes.remove(solver);
    let amount = stake.value();
    events::emit_solver_deregistered(solver, amount);
    coin::from_balance(stake, ctx)
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
    registry.solvers.contains(solver) && stake_of(registry, solver) >= config.min_solver_stake()
}

public fun stake_of<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    if (!registry.stakes.contains(solver)) return 0;
    registry.stakes.borrow(solver).value()
}

public fun available_stake_of<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    stake_of(registry, solver)
}

public fun total_settled<Stake>(registry: &SolverRegistry<Stake>, solver: address): u64 {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).total_settled
}

public fun url<Stake>(registry: &SolverRegistry<Stake>, solver: address): vector<u8> {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
    registry.solvers.borrow(solver).url
}

public fun assert_registered<Stake>(registry: &SolverRegistry<Stake>, solver: address) {
    assert!(registry.solvers.contains(solver), ESolverNotRegistered);
}

#[test_only]
public fun init_for_testing<Stake>(cap: &AdminCap, ctx: &mut TxContext): ID {
    init_registry<Stake>(cap, ctx)
}
