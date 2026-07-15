# The oracle already knew how volatile the stock was

Options are priced on one number: how much a stock moves. A chain has never had
that number, so every onchain options venue imports it. Someone runs a pricing
server, signs an answer, and the chain settles what they said.

The number was already there.

A Chainlink feed does not publish on a clock. It publishes when the price has
moved about half a percent, and not before. So a feed that updates every few
minutes is watching something that will not sit still, and one that goes quiet
for hours is watching something that has. **The gaps between updates are the
volatility.** You can read it without looking at a single price.

Take SpaceX, on the day this was written:

```
its Chainlink feed updated, on average, every 38 minutes
that spacing implies                                        70% a year
what its own price history says                             69% a year
```

Nobody told the contract that SpaceX is volatile. It counted timestamps.

## What that unlocks

An option can be priced in the transaction that buys it, with nobody quoting.
The second half of this repository is that market: seventeen real stocks, live
on Robinhood Chain mainnet, no quoter and no pricing server. One of the
seventeen is SpaceX, which is private, so its options exist here and on no
exchange in the world.

Every number below was measured against a public endpoint, and the script that
produced it is in this repository. Disagree by running it.

```
chain id   4663
rpc        https://rpc.mainnet.chain.robinhood.com
explorer   https://robinhoodchain.blockscout.com
```

Nothing here needs a key, an account or a wallet.

```
node scripts/01-chain.mjs
node scripts/02-stock-tokens.mjs
node scripts/03-how-stocks-trade.mjs
node scripts/04-cost-of-pushing.mjs 0x<a contract that pays holders by transfer>
node scripts/05-cost-of-not-pushing.mjs        # needs Foundry
```

---

## The idea, in one paragraph

A Chainlink feed publishes when the price has moved a fixed step and not before.
That makes its update times a record of how fast the price has been moving,
which is the volatility, and it can be read without looking at a single price:

    sigma = d * sqrt(year / mean interval between rounds)

The estimator is Cho and Frees, *Estimating the Volatility of Discrete Stock
Prices*, Journal of Finance 43(2), 1988, and the literature on price durations
that followed it. Nothing here improves on it. What is new is only that a
deviation-threshold oracle **is** their experiment, running continuously in
public with its results already stored: they had to construct passage events
from data, and a feed of this kind emits nothing else.

That matters because options are priced on volatility and a chain has never had
it. Every onchain options venue imports the number, from a server that signs it
or a market maker who quotes around it, and settles someone else's answer. This
one does not.
