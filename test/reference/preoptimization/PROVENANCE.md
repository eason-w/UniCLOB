# Pre-optimization RangeBook reference

First-party concentrated core and its dependencies frozen before the gas optimization pass.
Used only by behavioral equivalence tests and the identical-fixture gas baseline; production does not import this tree.
The production ABI and economic outcomes are compared against this reference.

Run `forge test --match-contract ConcentratedBaselineGasTest --gas-snapshot-emit true`
to generate a local baseline using the current gas fixture suite. Generated snapshots are not versioned.
