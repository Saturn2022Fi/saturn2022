// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gauss} from "./Gauss.sol";

/// An option priced on chain, in one call, with no oracle for the price of the
/// option itself. Spot comes from the stock's Chainlink feed; volatility comes
/// from the feed's own update cadence (see FeedVol); the rest is arithmetic.
library BlackScholes {
    using Gauss for int256;
    int256 internal constant ONE = 1e18;

    /// Call and put price for spot S, strike K, time T in years, vol sigma.
    /// All 1e18. Rates are taken as zero: these settle in USDG over days or
    /// weeks, and a rate term at that horizon is smaller than the vol noise.
    function price(int256 S, int256 K, int256 T, int256 sigma)
        internal
        pure
        returns (int256 call, int256 put)
    {
        int256 sqrtT = Gauss.sqrtFix(T);
        int256 sigSqrtT = (sigma * sqrtT) / ONE;
        int256 d1 = (Gauss.lnFix((S * ONE) / K) * ONE) / sigSqrtT
            + sigSqrtT / 2;
        int256 d2 = d1 - sigSqrtT;
        call = (S * Gauss.cdf(d1)) / ONE - (K * Gauss.cdf(d2)) / ONE;
        // Deep out of the money the two terms cancel to within rounding and the
        // difference can land a few wei below zero. A price is never negative.
        if (call < 0) call = 0;
        put = call - S + K;   // parity at zero rate
        if (put < 0) put = 0;
    }
}
