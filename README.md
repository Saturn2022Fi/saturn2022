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

## What the chain costs

```
$ node scripts/01-chain.mjs

block time    0.1007 s   (9.9 blocks per second)
median fee    $0.0078
reverted      7% to 13% of transactions, depending on the sample
```

Ten blocks a second invites designs that tick, so it is worth writing down what
ticking costs before building one:

| a transaction | per day |
|---|---|
| every block | $6,686 |
| once a second | $673 |
| once a minute | $11.22 |
| once an hour | $0.19 |

Blocks are fast. Gas is not free. A design that needs a heartbeat needs a budget,
and a design that computes its state from the block number instead needs neither.

## What it costs to pay every holder

Handing assets to holders by sending them is the obvious approach, and its cost
grows with the number of holders while the payout does not. Point the script at
any contract that does it and read the receipts of a real round:

```
$ node scripts/04-cost-of-pushing.mjs 0x<distributor> 40000

window               40,000 blocks (~67 min)
transfers sent       56,592
distinct recipients  3,139
distinct assets      19
transactions         132
event logs written   115,090
gas burned           1,171,714,619
cost                 $74.59

per recipient reached : $0.02376
per year              : $583,996
```

Nearly six hundred thousand dollars a year, spent on the act of handing over,
by one contract. Double the holders and it doubles. The payout does not.

`contracts/src/PayoutToken.sol` does the same job with one storage write:

```
$ node scripts/05-cost-of-not-pushing.mjs

action                  gas     cost
pay every holder, once  9,574   $0.000606
one holder claims       71,022  $0.004496
one holder transfers    47,237  $0.002990

holders  gas to pay them all
100      9,577
5,100    9,577
10,000   9,577
```

The same figure at every crowd size, because the payout writes a number instead
of walking a list. A holder pays half a cent to collect, once, whenever they
like, and that one collection settles every round that happened in between.

One asset, deliberately. An earlier version let a project pay out any number of
assets and kept a running total for each. Paying stayed cheap, but every holder
then carried the whole list on every transfer: with eighteen assets a transfer
cost 1,557,692 gas against 97,167 with one. The cost had not gone away, it had
moved onto the people the token is for.
