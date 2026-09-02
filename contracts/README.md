# Contracts

```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-commit
forge test -vv
forge test --match-contract ForkQuote --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

Deployed on Robinhood Chain mainnet (4663):

| contract | address |
|---|---|
| OptionHouse (17 markets) | `0xd8E48293DBfc9452F6c60850ebdE555af8d9E9Da` |
| OptionLens (free quotes) | `0x87A7593659E08b02098d4c3D8F3c236D0414dA81` |
| sSPCX vault | `0x7207EBc7493F66f62166fb951F14bB333C06297C` |
| sNVDA vault | `0x2Fbd30388365e1fD540BfE50CaF9cd995f068978` |

The other fifteen markets each have a vault too; the full list is the `VAULTS`
line in `../crank/README.md`.

## The pieces

`Gauss.sol`: exp, ln, sqrt and the normal CDF in 1e18 fixed point. The CDF is
Abramowitz-Stegun 7.1.26; the polynomial is Horner from a5 down, and folding it
the other way costs three percent of probability, which is why the reference
tests exist.

`BlackScholes.sol`: call and put at zero rate, 45,747 gas a price, checked
against double-precision references to a tenth of a cent, put-call parity
fuzzed.

`FeedVol.sol`: volatility from a Chainlink feed's update times alone. The feed
publishes on deviation, so the mean interval between rounds carries sigma:
`sigma = d * sqrt(year / mean_interval)`. No prices are read. The estimator is
Cho and Frees (1988); what a deviation feed adds is that it emits the passage
events rather than requiring them to be constructed.

Three things in it were measured rather than chosen. The window is 290 rounds,
because at 24 the ratio to realized volatility wandered with a coefficient of
variation of 18.8% against 3.8% at 290. Gaps longer than six hours are charged
at six, because these feeds follow market hours and a weekend counted as calm
reported a calm asset. And the raw estimate is divided by 0.915, the bias
measured across eighteen feeds, which is a constant rather than a fudge only
because its dispersion is 3.8%. A 290-round walk costs 1,465,419 gas.

`HoodStock.sol`: reads what a Robinhood Chain stock token actually is:
the dividend multiplier (display only; the feed price already carries it),
the announced-but-not-landed dividend, and the pause switch.

`OptionHouse.sol`: the market. Listing binds a stock to a feed and that feed's
measured threshold, and is held by the deployer; writing escrows a full share;
buying pays the model price to the writer. Settling takes a round id and splits
the escrow at the price that round carried, after checking it is the last round
at or before expiry: reading the feed at call time instead would let a buyer
wait past expiry for a better price. No margin, no liquidation, no quoter.

`CoveredCallVault.sol`: where the written shares come from. Depositors pool
stock, the vault writes calls against the pool through the house, and premiums
accrue per vault share with one storage write rather than a transfer each.
Escrowed shares cannot be withdrawn until their option settles; vault shares are
an ERC-20, so a depositor can leave by selling instead of waiting.

`PayoutToken.sol`: a token that pays every holder with one storage write,
kept from an earlier spike; its measurements are in the root README.

`CoveredCall.sol`: the single-market predecessor of OptionHouse, kept for the
test suite that grew on it.
