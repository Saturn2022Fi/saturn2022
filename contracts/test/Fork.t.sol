// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BlackScholes} from "../src/BlackScholes.sol";
import {FeedVol, IAggregator} from "../src/FeedVol.sol";

/// Against the live chain, not a mock: real Chainlink rounds, real timestamps.
/// Run with:  forge test --match-contract ForkQuote --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract ForkQuote is Test {
    struct Case { string name; address feed; }

    modifier onlyFork() {
        if (block.chainid != 4663) return;   // live-chain test; a plain run skips it
        _;
    }

    function _quote(string memory name, address feed) internal {
        (, int256 spot,,, ) = IAggregator(feed).latestRoundData();
        int256 vol = FeedVol.sigma(feed, 0.005264e18, 24);
        int256 spot18 = spot * 1e10;
        int256 strike = (spot18 * 110) / 100;              // 10% out of the money
        (int256 call,) = BlackScholes.price(spot18, strike, 0.08219178e18, vol); // 30 days

        emit log_named_string("asset", name);
        emit log_named_int("  spot ($, 1e2)", spot / 1e6);
        emit log_named_int("  vol from feed timing (bp)", vol / 1e14);
        emit log_named_int("  30d 110% call ($, 1e4)", call / 1e14);
        assertGt(vol, 0.05e18, "vol sane floor");
        assertLt(vol, 5e18, "vol sane cap");
        assertGt(call, 0);
        assertLt(call, spot18);
    }

    function test_quote_nvda() public onlyFork { _quote("NVDA", 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15); }
    function test_quote_spcx() public onlyFork { _quote("SPCX", 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb); }
    function test_quote_aapl() public onlyFork { _quote("AAPL", 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0); }
}
