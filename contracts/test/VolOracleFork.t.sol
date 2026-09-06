// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VolOracle} from "../src/VolOracle.sol";

/// Against the real LINK / USD feed on Base: what registration costs on a
/// Chainlink proxy, and whether the threshold measured on chain agrees with
/// the one the off-chain script measured for the same feed.
/// Runs only under --fork-url; skipped otherwise.
contract VolOracleForkTest is Test {
    address constant LINK_FEED = 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65;
    int256 constant SCRIPT_D = 5306589599748834;   // scripts/07 style, DeployBase.s.sol

    function test_fork_register_link() public {
        if (block.chainid != 8453) return;
        VolOracle oracle = new VolOracle();
        uint256 g = gasleft();
        (int256 d, uint256 n) = oracle.measure(LINK_FEED);
        emit log_named_uint("measure gas", g - gasleft());
        emit log_named_int("on-chain median move (1e18)", d);
        emit log_named_int("off-chain script move (1e18)", SCRIPT_D);
        emit log_named_uint("rounds with a move", n);
        g = gasleft();
        oracle.register(LINK_FEED);
        emit log_named_uint("register gas", g - gasleft());
        g = gasleft();
        int256 v = oracle.vol(LINK_FEED);
        emit log_named_uint("vol gas", g - gasleft());
        emit log_named_int("vol (1e18)", v);
    }
}
