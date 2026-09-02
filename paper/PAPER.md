# Deviation-threshold oracles are volatility instruments

**Abstract.** A price oracle that publishes on deviation rather than on a schedule records, in its update times alone, the volatility of the asset it tracks. The statistics are not new: the estimator is the passage-time method of Cho and Frees (1988), and nothing in this paper improves on it. The claim is narrower. A deviation-threshold oracle is their experiment, running continuously, in public, with its results already stored, so volatility can be read from timestamps without reading a single price. We validate this on Robinhood Chain mainnet against 18 Chainlink stock feeds, about 5,300 rounds, spanning realized volatilities from 21% to 95%. Over identical rounds the timestamp estimator tracks realized volatility at a stable ratio: at the full 290-round window the ratio's coefficient of variation is 3.8%, so one measured constant, 0.915, calibrates every feed at once, the calibrated mean is 1.000, and the worst asset sits at 0.918. The estimator a practitioner would naturally reach for, interval weighting, is off by more than 2x on 17 of the 18 feeds. The practical consequence is an options market that prices inside the transaction that buys, with no quoter. One is deployed on seventeen assets, one of which is a private company whose options exist nowhere else.

## The problem

Options are priced on volatility, and a chain has never had it. Spot price arrives through oracles, but the second input to every option formula does not, so every onchain options venue imports it: a server computes a volatility and signs it, or a market maker quotes around one. The chain then settles someone else's answer, which is the one thing a chain is supposed to remove. This is not an implementation detail. It is the reason onchain options have remained a wrapper around an offchain number.

## The observation

The statistical instrument is Cho and Frees, "Estimating the Volatility of Discrete Stock Prices", Journal of Finance 43(2), 1988, 451-466. Their framing: the natural estimator watches how much a price moved over an interval, while a first-passage estimator watches how quickly the price crosses a barrier of known size. A price constrained to move in discrete steps generates passage events, and the time between events carries the volatility. The literature that followed, on price durations and intensity models, is thirty-odd years deep. Nothing here improves on any of it, and saying otherwise would be both wrong and unnecessary.

What this paper adds is an identification, not an estimator. A deviation-threshold oracle is the Cho and Frees experiment, running continuously, in public, with its results already stored. A Chainlink feed of this kind does not publish on a clock. It publishes when the price has moved a fixed step d from the last published value, and not before. So a round appears exactly when the price has finished a move of size d, which is a passage event by construction. Cho and Frees had to construct passage events out of recorded data. A deviation feed emits nothing else. The experiment that had to be built is instead the data, and reading it costs one walk over round timestamps:

    sigma = d * sqrt(year / mean interval between rounds)

No price enters that expression. The prices the feed publishes need never be read, except once, to infer d itself.

## The data

Everything below was measured on Robinhood Chain mainnet, chain id 4663, block time 0.1007 s measured over 20,000 blocks, median transaction fee $0.0078. The endpoints are public and nothing requires a key or an account.

The dataset is the round history of 18 Chainlink stock feeds: up to 300 most recent rounds each, about 5,300 rounds in total, spanning from about a week to about two months per feed depending on how often each publishes. `scripts/08-dataset.mjs` pulls it and writes `out/rounds.json`; `scripts/09-validate.mjs` computes everything in Table 1.

One defect in the raw data is worth recording because any consumer walking round history will meet it. The S&P feed's earliest rounds answer at eighteen decimals where every later round answers at eight. Read straight through, the history shows a price of seventy-three billion dollars falling to about seven hundred, and a realized volatility of 7,812%. This is a real property of the published data, not a bug in the reading. The validation script drops any round whose price is more than a factor of one hundred from the feed's median price, treats it as a different unit, and reports the count rather than absorbing it silently. On this run, 7 SPY rounds were dropped and no other feed was affected.

The threshold d is not read from a configuration anywhere. It is inferred from the feed's own history as the median absolute return between consecutive rounds. The inferred thresholds cluster near half a percent: SLV at 0.5233%, AAPL at 0.5306%, SPCX at 0.5397%, with the full spread across feeds visible in Table 1. They differ enough across feeds, about 11% from lowest to highest on this run, that borrowing one feed's threshold for another is a measurable error, which is why each market in the deployed contract carries its own.

## The three estimators

All three run over identical rounds per feed.

**Realized.** The target. Sum of squared log returns between consecutive rounds, annualized over the time the market was open. This is what the prices themselves say, and the honest benchmark: a quoted implied volatility prices the future and carries a risk premium besides, so agreement with it is not the right test.

**Interval-weighted.** Each squared return divided by its own interval, averaged, annualized. This is the textbook handling of irregularly sampled prices, and it is the plausible mistake here. The samples are not irregular by accident. They are triggered by the returns themselves, so busy stretches oversample themselves, and dividing by short intervals amplifies exactly the stretches that are already over-represented.

**Passage.** d multiplied by the square root of a year over the mean active interval. Timestamps and one inferred constant. No prices.

Intervals in all three are capped at six hours, for a reason given with the results.

## Results

Table 1 is the verbatim output of `node scripts/09-validate.mjs 6` on the dataset described above.

**Table 1.** Three estimators over identical rounds, 18 feeds, sorted by realized volatility.

| ticker | rounds | dropped | days | d med % | d p10 % | realized % | passage % | pass/real | p10/real | weighted % | wtd/real |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SPY | 101 | 7 | 64 | 0.5084 | 0.1645 | 20.9 | 22.3 | 1.063 | 0.344 | 32 | 1.5 |
| AAPL | 299 | 0 | 41 | 0.5306 | 0.5030 | 41.3 | 38.1 | 0.924 | 0.875 | 165 | 4.0 |
| GOOGL | 300 | 0 | 34 | 0.5283 | 0.5020 | 42.5 | 40.8 | 0.959 | 0.911 | 140 | 3.3 |
| NVDA | 300 | 0 | 28 | 0.5255 | 0.5026 | 43.4 | 41.5 | 0.957 | 0.915 | 118 | 2.7 |
| SLV | 300 | 0 | 21 | 0.5233 | 0.5029 | 46.8 | 44.8 | 0.958 | 0.920 | 102 | 2.2 |
| META | 300 | 0 | 28 | 0.5319 | 0.5035 | 47.9 | 44.5 | 0.930 | 0.880 | 165 | 3.4 |
| TSLA | 300 | 0 | 26 | 0.5346 | 0.5031 | 48.0 | 45.6 | 0.951 | 0.895 | 142 | 3.0 |
| MSFT | 300 | 0 | 30 | 0.5373 | 0.5039 | 52.2 | 44.5 | 0.852 | 0.799 | 284 | 5.4 |
| AMZN | 300 | 0 | 29 | 0.5439 | 0.5057 | 55.6 | 46.7 | 0.840 | 0.781 | 297 | 5.3 |
| AMD | 300 | 0 | 16 | 0.5386 | 0.5043 | 56.4 | 52.4 | 0.928 | 0.869 | 174 | 3.1 |
| PLTR | 300 | 0 | 19 | 0.5431 | 0.5045 | 57.6 | 51.5 | 0.895 | 0.831 | 241 | 4.2 |
| ORCL | 300 | 0 | 16 | 0.5454 | 0.5057 | 59.9 | 54.9 | 0.917 | 0.850 | 279 | 4.7 |
| INTC | 300 | 0 | 12 | 0.5369 | 0.5044 | 67.4 | 62.4 | 0.926 | 0.870 | 190 | 2.8 |
| SPCX | 300 | 0 | 12 | 0.5397 | 0.5050 | 69.1 | 63.4 | 0.918 | 0.859 | 228 | 3.3 |
| MU | 300 | 0 | 8 | 0.5458 | 0.5064 | 76.0 | 71.3 | 0.938 | 0.871 | 190 | 2.5 |
| CRWV | 300 | 0 | 8 | 0.5650 | 0.5072 | 88.2 | 77.6 | 0.879 | 0.789 | 266 | 3.0 |
| SNDK | 300 | 0 | 7 | 0.5510 | 0.5096 | 93.1 | 84.5 | 0.907 | 0.839 | 239 | 2.6 |
| USAR | 300 | 0 | 7 | 0.5642 | 0.5120 | 94.9 | 83.7 | 0.882 | 0.800 | 284 | 3.0 |

Summary lines from the same run: passage over realized has mean 0.924, median 0.926, standard deviation 0.048, coefficient of variation 5.2% across all 18 rows. With d read at the 10th percentile instead: mean 0.828, CV 15.0%. The interval-weighted estimator is off by more than 2x on 17 of 18 feeds, 3.3x on average.

Three readings of that table.

**Stability, not accuracy, is the claim.** The passage estimator reads no prices, so what matters is not that its raw ratio to realized is 1.0 but that the ratio is the same across assets. A bias that is the same size everywhere is a constant to divide out; one that wanders is not. The 5.2% figure above includes SPY, whose clean history after the unit scrub is only 101 rounds and which sits, as the window study below predicts, wide of the pack. At the full 290-round window the ratio's coefficient of variation is 3.8%. Dividing out the measured bias of 0.915 puts the calibrated mean at 1.000 and the worst asset, AMZN, at 0.918, across a dataset spanning 21% to 95% realized volatility. One constant, measured once, calibrates every feed.

**The obvious estimator fails, and in one direction.** Interval weighting overstates volatility on every feed, by 1.5x at best and 5.4x at worst. The mechanism is the sampling itself: a deviation feed publishes when the price moves, so short intervals and large squared returns arrive together, and weighting by the interval doubles down on the coincidence. Anyone treating a deviation feed's rounds as ordinary irregular samples inherits this error.

**One worked example.** SpaceX, the one asset in the set with no listed options anywhere because the company is private. Its feed updated on average every 38 minutes of active time over the window. That spacing alone, through the threshold and the calibration constant, says 70% a year. Its own price history over the same rounds says 69%. The ratio is 1.003. Nobody told the contract that SpaceX is volatile. It counted timestamps.

### The window has to be long

The same validation was run at truncated windows. The cross-asset CV of the passage-to-realized ratio, by rounds per feed: 12 rounds, 22.3%; 24 rounds, 18.8%; 50 rounds, 16.6%; 100 rounds, 14.3%; 200 rounds, 7.3%; 290 rounds, 3.6% to 3.8%. At 24 rounds a single asset's ratio wandered between 0.72 and 0.93 depending on which 24. A handful of passages can be one quiet afternoon or one earnings day. The round count, not the elapsed time, is what fixes it.

### Market hours are not quiet hours

These feeds follow the underlying's trading sessions, so a weekend inside a window is roughly fifty hours containing no rounds at all. Counted as calm, it reports a calm asset: on one feed the uncorrected figure was low by a third. The correction is blunt and stated in the open: any interval is charged at six hours and no more, in all three estimators alike. Table 1 is computed with that cap.

## What we predicted and got wrong

A round appears once the move has passed the threshold, so every observed inter-round move is d plus an overshoot, and the median absolute return should read the barrier high. A low quantile sits nearer the barrier itself, since the moves that only just triggered a publish are the ones that overshot least. The prediction was therefore that the 10th percentile would recover d better than the median and tighten the cross-asset ratio.

It did the opposite. With d at the 10th percentile the cross-asset dispersion got worse, CV 15.0% against 5.2%, and the SPY row shows the failure at its most extreme. Both columns are in Table 1 so the reader can see it rather than take it. The median is the better read and we do not have a clean account of why. It is recorded here as a finding, not explained away.

## The practical consequence

If volatility can be read from a feed the chain already has, an option can be priced inside the transaction that buys it, with no quoter and no pricing server. A market doing exactly that is live on this chain:

    OptionHouse   0x2575218b2A42301E2001fEf989fe514D513F1433
    OptionLens    0x87A7593659E08b02098d4c3D8F3c236D0414dA81

Seventeen markets, each with its own measured threshold. Writing a call escrows the whole share, so positions are fully collateralized and there is no margin or liquidation machinery; premiums go to writers at purchase; settlement is pinned to the oracle round covering expiry rather than read at call time. Each market carries a public markup, set at 30%, which is what stands between a writer and selling too cheap.

The cost of reading volatility this way is small and lands only where it should. The 290-round timestamp walk costs 1,465,419 gas, about nine cents at the measured median fee, and the Black-Scholes arithmetic costs 45,747 gas. A quote through OptionLens is a view and free. The walk is paid only inside the transaction that buys.

One of the seventeen assets is SpaceX, which is private, so its options exist in this contract and on no exchange in the world. At the calibrated full-window volatility, a 30-day call struck 10% above spot prices at $5.78 to $5.82. The first such option sold live was priced at $2.02 by an earlier lens using a short uncalibrated window, and the distance between those two numbers is the window study of the previous section expressed in dollars.

## Honest limits

**The threshold is inferred, and the estimate scales with it.** d comes from published moves, not from a configuration, and sigma is linear in d. This is the one place prices enter and the one place bias can. The p10 anomaly above lives exactly here and remains open.

**The calibration constant is an empirical fact of this dataset.** The 0.915 bias was measured on one chain, one oracle vendor, and weeks to months of history per feed. Nothing here argues it transfers to other feeds, other deviation parameters, or other regimes; it is remeasured the same way it was measured.

**Volatility error amplifies away from the money.** A 9% volatility error is a 9% price error at the money, 21% at 10% out, 37% at 20% out, because an out-of-the-money option is almost entirely a bet on movement. The validation above supports at-the-money and near-the-money writing. Deep out-of-the-money quotes are published because the model produces them, and they carry that amplification against the markup.

**A gap to implied volatility is expected and is not error.** This estimator measures volatility that has been; an option is priced on volatility to come, and implied volatility carries a risk premium over realized for exactly that reason. Agreement with the realized figure from the same rounds is the claim. Agreement with an options market is not.

## Reproduction

Everything is plain Node with no dependencies, against public endpoints, with no key, account, or wallet:

    rpc  https://rpc.mainnet.chain.robinhood.com   (chain id 4663)

    git clone https://github.com/Saturn2022Fi/saturn2022-tools && cd saturn2022-tools
    node scripts/08-dataset.mjs 300     # pulls round history, writes out/rounds.json
    node scripts/09-validate.mjs 6      # Table 1, with intervals capped at 6 hours

The feeds keep publishing, so a rerun sees a slightly different window than the one printed here. The claim is that the summary statistics hold, not that the individual rows freeze. Disagreement with this paper should take the form of running it.

## Reference

Cho, D. Chinhyung, and Edward W. Frees. "Estimating the Volatility of Discrete Stock Prices." Journal of Finance 43(2), 1988, 451-466.
