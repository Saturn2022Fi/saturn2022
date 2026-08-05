// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// The math Solidity does not have, in 1e18 fixed point: exp, ln, sqrt, and the
/// standard normal CDF. Everything an option price is made of.
library Gauss {
    int256 internal constant ONE = 1e18;

    error OutOfRange();

    /// e^x for x in [-42, 135] roughly. Bit-decomposition against precomputed
    /// powers of two: exact structure, no series truncation drift.
    function expFix(int256 x) internal pure returns (int256) {
        if (x < -41.5e18) return 0;             // e^-41.5 is below 1 wei
        if (x >= 135e18) revert OutOfRange();
        bool neg = x < 0;
        if (neg) x = -x;

        // integer part via repeated squaring of e, fractional via series
        uint256 xi = uint256(x) / 1e18;
        int256 xf = x % ONE;

        // e^frac by Taylor, 12 terms: |error| < 1e-19 on [0,1)
        int256 term = ONE;
        int256 sum = ONE;
        for (uint256 i = 1; i <= 12; i++) {
            term = (term * xf) / ONE / int256(i);
            sum += term;
        }

        // e^int by square-and-multiply on E = e * 1e18
        int256 E = 2718281828459045235;
        int256 acc = ONE;
        int256 base = E;
        uint256 n = xi;
        while (n > 0) {
            if (n & 1 == 1) acc = (acc * base) / ONE;
            base = (base * base) / ONE;
            n >>= 1;
        }
        int256 out = (acc * sum) / ONE;
        return neg ? (ONE * ONE) / out : out;
    }

    /// ln(x) for x > 0. Range-reduce into [1, 2) by powers of two, then
    /// atanh series, which converges fast on that interval.
    function lnFix(int256 x) internal pure returns (int256) {
        if (x <= 0) revert OutOfRange();
        int256 LN2 = 693147180559945309;
        int256 k = 0;
        while (x >= 2e18) { x = x / 2; k++; }
        while (x < 1e18) { x = x * 2; k--; }
        // ln(x) = 2 atanh((x-1)/(x+1))
        int256 y = ((x - ONE) * ONE) / (x + ONE);
        int256 y2 = (y * y) / ONE;
        int256 term = y;
        int256 sum = y;
        for (uint256 i = 3; i <= 15; i += 2) {
            term = (term * y2) / ONE;
            sum += term / int256(i);
        }
        return k * LN2 + 2 * sum;
    }

    function sqrtFix(int256 x) internal pure returns (int256) {
        if (x < 0) revert OutOfRange();
        if (x == 0) return 0;
        uint256 xx = uint256(x) * 1e18;
        uint256 z = (xx + 1) / 2;
        uint256 y = xx;
        while (z < y) { y = z; z = (xx / z + z) / 2; }
        return int256(y);
    }

    /// Standard normal CDF via Abramowitz-Stegun 7.1.26 on erf.
    /// |error| < 1.5e-7, which prices an option to a hundredth of a cent.
    function cdf(int256 x) internal pure returns (int256) {
        bool neg = x < 0;
        if (neg) x = -x;
        // z = x / sqrt(2)
        int256 z = (x * ONE) / 1414213562373095049;
        // t = 1 / (1 + p z), p = 0.3275911
        int256 t = (ONE * ONE) / (ONE + (327591100000000000 * z) / ONE);
        // Horner from a5 down to a1, then one final multiply by t
        int256 poly = 1061405429000000000;                    // a5
        poly = (poly * t) / ONE - 1453152027000000000;        // a4
        poly = (poly * t) / ONE + 1421413741000000000;        // a3
        poly = (poly * t) / ONE - 284496736000000000;         // a2
        poly = (poly * t) / ONE + 254829592000000000;         // a1
        poly = (poly * t) / ONE;
        int256 erfv = ONE - (poly * expFix(-(z * z) / ONE)) / ONE;
        int256 c = (ONE + erfv) / 2;
        return neg ? ONE - c : c;
    }
}
