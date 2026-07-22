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

## The thing that will bite you first

A Robinhood Chain stock token is an ERC-20 with the ERC-8056 scaled-amount
extension on top. A dividend does not move anyone's balance: it raises a
multiplier, so one token comes to stand for more than one share while
`balanceOf` reports the number it always did.

The trap is not where it looks. The Chainlink feed for a stock token already
returns the multiplier-adjusted price, per Robinhood's own documentation: "the
feed returns the price of one token, which is the underlying share price times
the multiplier... so you don't apply the multiplier yourself." So the obvious
read is right:

```
value = balanceOf(a) x feedPrice          correct
value = balanceOf(a) x feedPrice x uiMultiplier()   counts the dividend twice
```

An earlier version of this file claimed the opposite, that reading `balanceOf`
alone undercounts. It does not, as long as the price comes from the feed. It is
recorded here because the mistake is the easy one to make from chain data alone,
and the documentation is what settles it.

What is true, and worth holding on to:

| call | what it answers |
|---|---|
| `balanceOf(a)` | tokens held. Unmoved by dividends. |
| `balanceOfUI(a)` | the same position counted in shares. |
| `uiMultiplier()` | shares per token, 1e18 based. Use it for display, not for value. |
| `newUIMultiplier()` / `effectiveAt()` | the next multiplier and when it takes over. |
| `tokenPaused()` / `oraclePaused()` | whether the asset can move at all. |

```
$ node scripts/02-stock-tokens.mjs

ticker  uiMultiplier          dividends so far
AAPL    1.000566080061092436  +0.0566%
MU      1.000074823219171086  +0.0075%
ORCL    1.002210914971013375  +0.2211%
SGOV    1.002981519346766532  +0.2982%
...
```

Two properties have no equivalent on a plain ERC-20 and are worth designing
around. A stock token can be paused, so a contract that promises to hand one
over later should check before making the promise. And a dividend is announced
before it lands, through `newUIMultiplier` and `effectiveAt`, so a contract can
see a corporate action coming rather than discovering it afterwards.

`contracts/src/HoodStock.sol` reads all of it, and answers `1.0` on a plain
ERC-20 so one code path covers both.

Feeds update 24/5 and follow market hours, which is why a week of feed history
carries a gap of two days and change. They publish on deviation rather than on a
heartbeat, so the interval between updates is anything from a minute to two
days, and a quiet feed means a still price rather than a broken one.

## Where a stock purchase actually goes

Not to a pool. Quotes are signed off chain by market makers holding real
inventory, and the chain settles them. Robinhood's ecosystem page calls the
venue a "PropAMM driven spot exchange"; decoded from live fills, that means a
signed quote, a maker vault, and a five basis point fee.

```
$ node scripts/03-how-stocks-trade.mjs

fills            761 in 168 minutes
distinct takers  62
notional         $60,448      (about $519,000 a day at this rate)

route          fills  notional
USDG -> COIN   68     $2,183
USDG -> NVDA   43     $5,782
USDG -> SPCX   29     $30,147
...
```

Two things stand out. Sixty-two takers, so this is a rail that programs use
rather than people. And half the money through it is SpaceX, the one private
company on the chain and the only asset here that cannot be bought anywhere
else.

Five basis points is worth holding next to the 1% tier the stock pools charge.
Thin pools are not the constraint they look like, if you are willing to settle
against a signed quote instead.
