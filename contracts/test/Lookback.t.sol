// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FeedVol} from "../src/FeedVol.sol";

/// What a longer window costs. Off chain the answer got five times steadier
/// going from 24 rounds to 290; the question is whether a contract can afford
/// to walk that many, since each one is a call into the aggregator.
///   forge test --match-contract Lookback --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract LookbackTest is Test {
    address constant SPCX = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address constant NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    int256 constant DEV = 5395404172112830;

    function test_gas_by_window() public {
        if (block.chainid != 4663) return;
        uint80[6] memory ws = [uint80(24), 50, 100, 200, 290, 400];
        for (uint256 i = 0; i < ws.length; i++) {
            uint256 g = gasleft();
            int256 v = FeedVol.sigma(SPCX, DEV, ws[i]);
            g -= gasleft();
            emit log_named_uint("window", ws[i]);
            emit log_named_uint("  gas ", g);
            emit log_named_int("  vol (bp)", v / 1e14);
        }
    }

    function test_long_window_still_answers_on_a_young_feed() public {
        if (block.chainid != 4663) return;
        // Asking for more rounds than a feed has must not revert: the loop
        // stops when history runs out and divides by what it counted.
        int256 v = FeedVol.sigma(NVDA, 5206942968134557, 5000);
        emit log_named_int("NVDA with a 5000-round ask (bp)", v / 1e14);
        assertGt(v, 0.05e18);
        assertLt(v, 3e18);
    }
}
