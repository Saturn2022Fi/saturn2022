// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VolOracle} from "../src/VolOracle.sol";
import {VolRing} from "../src/VolRing.sol";
import {FeedVol} from "../src/FeedVol.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

/// The oracle must answer what the walk answers, from every state the ring
/// can be in, and its threshold must be the median the off-chain script took.
contract VolOracleTest is Test {
    VolOracle oracle;
    HistoryFeed feed;
    int256 price = 100e8;
    uint256 t = 1_700_000_000;

    function setUp() public {
        oracle = new VolOracle();
        feed = new HistoryFeed();
    }

    /// A feed that moves by about half a percent each round on an uneven
    /// clock, with the occasional repeated price and a closed market now and then.
    function seed(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            uint256 k = uint256(keccak256(abi.encode(i))) % 7;
            t += k == 6 ? 60 hours : 20 minutes + k * 9 minutes;
            if (k == 3) { feed.push(price, t); continue; }          // heartbeat, no move
            int256 step = int256(uint256(keccak256(abi.encode(i, "p"))) % 40) - 20;  // -0.2% .. +0.2%
            price += (price * (50 + step)) / 10_000 * (k % 2 == 0 ? int256(1) : -1);
            feed.push(price, t);
        }
    }

    function test_measure_is_the_median_move() public {
        seed(300);
        (int256 d, uint256 n) = oracle.measure(address(feed));
        // Every non-heartbeat round moved between 0.3% and 0.7%.
        assertGt(d, 0.003e18);
        assertLt(d, 0.007e18);
        // 290 rounds walked, about one in seven a heartbeat.
        assertGt(n, 230);
        assertLe(n, 290);
    }

    function test_register_then_vol_is_the_walk() public {
        seed(300);
        oracle.register(address(feed));
        int256 d = oracle.deviation(address(feed));
        assertEq(oracle.vol(address(feed)), FeedVol.sigma(address(feed), d, 290));
    }

    function test_vol_stays_current_without_sync() public {
        seed(300);
        oracle.register(address(feed));
        int256 d = oracle.deviation(address(feed));
        (uint16 c0, uint80 r0,) = oracle.ring(address(feed));
        assertEq(c0, 290);

        seed(5);   // the feed moves on; nobody syncs
        (, uint80 r1,) = oracle.ring(address(feed));
        assertEq(r1, r0, "ring untouched");
        assertEq(oracle.vol(address(feed)), FeedVol.sigma(address(feed), d, 290), "answer moved with the feed");

        seed(290); // exactly a window: every old gap evicted in memory
        assertEq(oracle.vol(address(feed)), FeedVol.sigma(address(feed), d, 290));

        seed(3);   // past a window: falls back to the walk
        assertEq(oracle.vol(address(feed)), FeedVol.sigma(address(feed), d, 290));

        oracle.sync(address(feed));
        (, uint80 r2,) = oracle.ring(address(feed));
        assertEq(r2, feed.latest());
        assertEq(oracle.vol(address(feed)), FeedVol.sigma(address(feed), d, 290));
    }

    function test_register_gas() public {
        seed(300);
        uint256 g = gasleft();
        oracle.measure(address(feed));
        emit log_named_uint("walk + median gas", g - gasleft());
        g = gasleft();
        oracle.register(address(feed));
        uint256 used = g - gasleft();
        emit log_named_uint("register gas", used);
        assertLt(used, 8_000_000);
    }

    function test_vol_read_gas_when_synced() public {
        seed(300);
        oracle.register(address(feed));
        uint256 g = gasleft();
        oracle.vol(address(feed));
        uint256 used = g - gasleft();
        emit log_named_uint("vol gas, synced", used);
        assertLt(used, 30_000);
    }

    function test_refuses_twice_and_unregistered_and_young() public {
        seed(300);
        oracle.register(address(feed));
        vm.expectRevert(VolOracle.AlreadyRegistered.selector);
        oracle.register(address(feed));

        HistoryFeed other = new HistoryFeed();
        vm.expectRevert(VolOracle.NotRegistered.selector);
        oracle.vol(address(other));

        for (uint256 i = 0; i < 20; i++) other.push(100e8 + int256(i) * 1e7, 1_700_000_000 + i * 600);
        vm.expectRevert(FeedVol.TooFewRounds.selector);
        oracle.register(address(other));
    }
}
