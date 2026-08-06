// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BlackScholes} from "../src/BlackScholes.sol";
import {Gauss} from "../src/Gauss.sol";

contract BlackScholesTest is Test {
    // References computed off chain with double-precision floats.
    // The tolerance is a tenth of a cent on prices in dollars.
    int256 constant TOL = 1e15;

    function _check(int256 S, int256 K, int256 T, int256 sig, int256 refCall, int256 refPut) internal pure {
        (int256 c, int256 p) = BlackScholes.price(S, K, T, sig);
        assertApproxEqAbs(c, refCall, uint256(TOL));
        assertApproxEqAbs(p, refPut, uint256(TOL));
    }

    function test_atm_30d() public pure {
        _check(214e18, 214e18, 0.08219178e18, 0.55e18, 13.447792e18, 13.447792e18);
    }

    function test_otm_call() public pure {
        _check(214e18, 250e18, 0.08219178e18, 0.55e18, 3.113938e18, 39.113938e18);
    }

    function test_itm_call() public pure {
        _check(214e18, 180e18, 0.08219178e18, 0.55e18, 36.130684e18, 2.130684e18);
    }

    function test_spcx_high_vol() public pure {
        _check(138e18, 150e18, 0.03835616e18, 0.8e18, 4.232223e18, 16.232223e18);
    }

    function test_one_week() public pure {
        _check(214e18, 220e18, 0.01917808e18, 0.4e18, 2.379964e18, 8.379964e18);
    }

    function test_gas_one_price() public {
        uint256 g = gasleft();
        BlackScholes.price(214e18, 250e18, 0.08219178e18, 0.55e18);
        g -= gasleft();
        emit log_named_uint("gas for one option price", g);
        assertLt(g, 100_000);
    }

    // The building blocks, against known values.
    function test_exp() public pure {
        assertApproxEqAbs(Gauss.expFix(1e18), 2718281828459045235, 1e9);
        assertApproxEqAbs(Gauss.expFix(-1e18), 367879441171442321, 1e9);
        assertApproxEqAbs(Gauss.expFix(0), 1e18, 0);
        assertApproxEqAbs(Gauss.expFix(10e18), 22026465794806716516980, 1e13);
    }

    function test_ln() public pure {
        assertApproxEqAbs(Gauss.lnFix(2718281828459045235), 1e18, 1e9);
        assertApproxEqAbs(Gauss.lnFix(1e18), 0, 1e9);
        assertApproxEqAbs(Gauss.lnFix(0.5e18), -693147180559945309, 1e9);
        assertApproxEqAbs(Gauss.lnFix(100e18), 4605170185988091368, 1e10);
    }

    function test_cdf() public pure {
        assertApproxEqAbs(Gauss.cdf(0), 0.5e18, 1e11);
        assertApproxEqAbs(Gauss.cdf(1e18), 841344746068542949, 3e11);   // N(1)
        assertApproxEqAbs(Gauss.cdf(-1e18), 158655253931457051, 3e11); // N(-1)
        assertApproxEqAbs(Gauss.cdf(2e18), 977249868051820793, 3e11);  // N(2)
    }

    function testFuzz_parity_holds(uint96 s, uint96 k, uint32 t, uint32 v) public pure {
        int256 S = int256(bound(uint256(s), 1e18, 10_000e18));
        int256 K = int256(bound(uint256(k), 1e18, 10_000e18));
        int256 T = int256(bound(uint256(t), 0.002e9, 1e9)) * 1e9;
        int256 sig = int256(bound(uint256(v), 0.05e9, 3e9)) * 1e9;
        (int256 c, int256 p) = BlackScholes.price(S, K, T, sig);
        // put-call parity at zero rate: C - P = S - K
        assertApproxEqAbs(c - p, S - K, 1e10);
        // a price is never negative and never above its bound
        assertGe(c, -1);
        assertLe(c, S + 1e10);
    }
}
