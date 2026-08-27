# Deviation-threshold oracles are volatility instruments

Working outline. Every number cited here must come from `scripts/08-dataset.mjs`
and `scripts/09-validate.mjs` in this repository, run against public endpoints,
so a reader disagrees by re-running rather than by argument.

## The claim, in one sentence

A price oracle that publishes on deviation rather than on a schedule records,
in its update times alone, the volatility of the asset it tracks. Nothing else
about the oracle is needed, and the prices it publishes need never be read.

## Why it is worth saying

Options are priced on volatility, and a chain has never had it. Every onchain
options venue therefore imports the number: a server computes it and signs, or a
market maker quotes around it. The chain settles someone else's answer, which is
the one thing a chain is supposed to remove. This gap is not an implementation
detail. It is the reason onchain options have stayed a wrapper around an offchain
price.

## What is not new

The statistical instrument is Cho and Frees, *Estimating the Volatility of
Discrete Stock Prices*, Journal of Finance 43(2), 1988, 451-466. Their framing:
the natural estimator watches how much a price moved; a passage-time estimator
watches how quickly. The literature that followed, on price durations and
intensity models, is thirty-odd years deep.

Nothing in this paper improves that estimator. Saying otherwise would be both
wrong and unnecessary.

## What is new

That a deviation-threshold oracle **is** the first-passage experiment, running
continuously, in public, with its results already stored and free to read.

Cho and Frees needed a discretization to create passage events. A deviation feed
creates them by construction: a round appears when the price has finished a move
of size d, and at no other time. The experiment that had to be constructed from
data is instead the data.

## The three estimators

Over the same rounds:

1. **Realized.** Sum of squared log returns, annualized over open time. The target.
2. **Interval-weighted.** Each squared return divided by its own gap. The obvious
   handling of irregular samples, and wrong here: sampling is triggered by the
   returns, so busy stretches oversample themselves.
3. **Passage.** `sigma = d * sqrt(year / mean interval)`, reading no prices.

## Findings to fill from the dataset

- [ ] Table 1: every feed, rounds, threshold, three estimators, ratios
- [ ] The interval-weighted estimator's error, distribution across feeds
- [ ] Passage / realized: mean, median, dispersion. **Stability is the claim,
      not accuracy**: an estimator reading no prices that tracks the realized
      figure at a fixed ratio is calibratable; one that wanders is not
- [ ] Threshold dispersion across feeds and what borrowing one costs
- [ ] Market-hours correction: these feeds follow the underlying's hours, so a
      weekend inside a window is not a quiet market. Effect size per feed

## Practical consequence

An option can then be priced in the transaction that buys it, with no quoter.
The market described in `contracts/` does this on seventeen assets, one of them a
company with no listed options anywhere because it is private.

## Honest limits

- Threshold d is inferred from published moves, not read from a config, and the
  estimate scales linearly with it
- Overshoot: an observed move is at least d, so the median absolute return is a
  biased read of d, and the direction of that bias needs stating
- Implied volatility carries a risk premium and prices the future; a gap between
  this estimator and a quoted IV is expected and is not error
- One chain, one oracle vendor, a few months of history
