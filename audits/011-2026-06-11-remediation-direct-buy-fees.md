# Review 011 — Direct Buy-token fees supersede numeraire-only v1

## Scope

Re-review of the F-009-1 / 010 remediation after product decision to support arbitrary directed
`Sell -> Buy` pairs on mainnet instead of a numeraire-only launch.

## [Fixed] F-009-1 — cross-token reward and fee-unit mixing

The numeraire-only gate from review 010 is superseded. The protocol no longer routes settlement
through a single accounting token and no longer normalizes settlement surplus on-chain.

Current invariant:

- `add_supported_pair<Sell, Buy>` requires `FeeVault<Buy>` to be registered.
- `settlement::settle_intent<Sell, Buy, Stake>` takes `payout: Coin<Buy>`.
- Protocol fee and immediate solver fee are split directly from `Coin<Buy>`.
- Protocol fee deposits into `FeeVault<Buy>`.
- User receives net payout in the requested `Buy` token.

This removes the old cross-token budget issue because there is no single numeraire vault paying
rewards for fees collected in other token units. Any off-chain quote ranking or analytics may still
normalize by USD/WUSDC, but that is not a settlement invariant.

## Regression

- `config_tests::test_non_usdc_buy_pair_supported_with_fee_vault`
- `config_tests::test_supported_pair_requires_buy_fee_vault`
- `flow_tests::test_non_usdc_buy_settles_and_collects_fee_in_buy_token`

## Operational Notes

Setup order is now:

1. Initialize and bind `SolverRegistry<Stake>`.
2. Initialize/register `FeeVault<Buy>` for every Buy token in `SUPPORTED_PAIRS`.
3. Set the execution coordinator key.
4. Allowlist supported pairs.

`scripts/setup.sh` enforces this order and can create missing `FeeVault<Buy>` objects from
`SUPPORTED_PAIRS`.
