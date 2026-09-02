// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gauss} from "./Gauss.sol";

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Volatility read off a Chainlink feed without reading a single price.
///
/// These feeds publish on deviation: a new round appears when the price has
/// moved by the feed's threshold, and not before. So the update times alone
/// carry the volatility. A random walk first crosses a barrier of width d in
/// d^2/sigma^2 expected time; invert that and the annualized vol is
///
///     sigma = d * sqrt(seconds_per_year / mean_update_interval)
///
/// The technique is Cho and Frees, "Estimating the Volatility of Discrete Stock
/// Prices", Journal of Finance 43(2), 1988. Their line for it: the natural
/// estimator watches how much the price moved, a passage-time estimator watches
/// how quickly. What is new here is only that a deviation-threshold oracle is
/// exactly that experiment, running in public, with its results already stored.
///
/// No prices, no log-returns, no history kept. The chain wrote the history;
/// this reads the last N timestamps and divides.
///
/// Two things break a naive reading of this data:
///
/// Weighting returns by their interval triples the answer, because sampling is
/// event-driven and busy stretches oversample themselves. Counting crossings
/// does not have that bias.
///
/// And these feeds follow market hours, so an interval can contain a weekend
/// the price could not have moved through. Counting that as quiet time reports
/// a quiet asset: measured against live feeds it cost a third of the figure on
/// one name. Any interval longer than `MAX_ACTIVE_GAP` is therefore counted as
/// that much and no more, which charges the estimator for the time the market
/// was open and not for the time it was shut.
library FeedVol {
    int256 internal constant ONE = 1e18;
    int256 internal constant YEAR = 31_557_600; // 365.25 days

    /// What the passage estimator reads low by, and the constant that removes it.
    ///
    /// Against the realized volatility computed from the same rounds, across
    /// eighteen feeds and about five thousand three hundred rounds, the raw
    /// estimate came in at 0.915 of the target, steadily rather than randomly:
    /// the coefficient of variation across assets was 3.8% over a full window,
    /// on assets whose volatility ranged from 21% to 95%. A bias that stable is
    /// a constant, so it is divided out here and named rather than left in the
    /// answer for a caller to discover. The measurement is `scripts/09-validate.mjs`.
    int256 internal constant CALIBRATION = 1_092_896_174_863_388;  // 1e18 / 0.915, scaled

    /// The window the calibration was measured at.
    ///
    /// Shorter windows are not merely noisier, they are differently biased: at
    /// 24 rounds the ratio to realized volatility moved 0.72 to 0.93 across
    /// assets, and the coefficient of variation was 18.8%. The estimate needs
    /// enough passages that one quiet afternoon or one earnings day cannot own
    /// it, and the count rather than the elapsed time is what supplies that.
    uint80 internal constant WINDOW = 290;

    /// The longest gap taken at face value. Beyond this the feed was not quiet,
    /// it was closed: these publish 24/5 and a weekend leaves fifty hours or
    /// more with no rounds in it. Six hours is longer than any gap seen on an
    /// active feed and far shorter than a weekend, so it separates the two
    /// without needing a market calendar on chain.
    uint256 internal constant MAX_ACTIVE_GAP = 6 hours;

    error TooFewRounds();

    /// Annualized vol, 1e18. `deviation` is the feed's publish threshold
    /// (e.g. 0.005e18 for half a percent), `lookback` how many rounds to span.
    ///
    /// Walks the rounds rather than taking the span end to end, so a closed
    /// market can be charged at `MAX_ACTIVE_GAP` instead of at its full length.
    function sigma(address feed, int256 deviation, uint80 lookback)
        internal
        view
        returns (int256)
    {
        if (lookback < 2) revert TooFewRounds();
        (uint80 latest,,, uint256 tPrev,) = IAggregator(feed).latestRoundData();
        if (tPrev == 0) revert TooFewRounds();

        uint256 active = 0;
        uint256 counted = 0;
        for (uint80 i = 1; i <= lookback; i++) {
            (,,, uint256 t,) = IAggregator(feed).getRoundData(latest - i);
            if (t == 0 || t >= tPrev) break;          // history ends, or is not ordered
            active += cap(tPrev - t);
            counted++;
            tPrev = t;
        }
        return fromMean(active, counted, deviation);
    }

    /// A gap charged for the time the market was open: anything longer than
    /// MAX_ACTIVE_GAP was a closed market, and counts as that much.
    function cap(uint256 gap) internal pure returns (uint256) {
        return gap > MAX_ACTIVE_GAP ? MAX_ACTIVE_GAP : gap;
    }

    /// The estimate from the sum of `counted` capped gaps:
    /// sigma = d * sqrt(YEAR / meanDt), then the measured bias divided out.
    /// Pure, so the same number comes out whether the gaps were just walked
    /// off the feed or kept in storage and extended one round at a time.
    function fromMean(uint256 active, uint256 counted, int256 deviation) internal pure returns (int256) {
        if (counted == 0 || active == 0) revert TooFewRounds();
        int256 meanDt = int256(active) * ONE / int256(counted);
        int256 ratio = (YEAR * ONE * ONE) / meanDt;
        int256 raw = (deviation * Gauss.sqrtFix(ratio)) / ONE;
        return (raw * CALIBRATION) / (ONE / 1000);
    }

    /// The reading a market should use: the calibrated estimate over the window
    /// the calibration was measured at.
    function sigma(address feed, int256 deviation) internal view returns (int256) {
        return sigma(feed, deviation, WINDOW);
    }
}
