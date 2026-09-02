// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VolRing} from "../src/VolRing.sol";
import {FeedVol} from "../src/FeedVol.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

/// A ring in a contract, so the library's storage functions can be driven.
contract RingHarness {
    using VolRing for VolRing.State;

    VolRing.State internal s;

    function sync(address feed) external { s.sync(feed); }
    function sigma(int256 d) external view returns (int256) { return s.sigma(d); }
    function count() external view returns (uint16) { return s.count; }
    function lastRound() external view returns (uint80) { return s.lastRound; }
}

/// The ring must be the walk, exactly, from every direction it can be reached:
/// cold, extended by a few rounds, rebuilt after falling a window behind, and
/// on a feed too young to fill it. Then the number the whole thing exists for,
/// what a purchase costs.
contract VolRingTest is Test {
    int256 constant DEV = 0.005395e18;
    HistoryFeed feed;
    RingHarness ring;

    function setUp() public {
        feed = new HistoryFeed();
        ring = new RingHarness();
    }

    /// Rounds on an uneven cadence, with a closed market inside the window now and then.
    function seed(uint256 n, uint256 startT) internal returns (uint256 t) {
        t = startT;
        for (uint256 i = 0; i < n; i++) {
            uint256 gap = 300 + (uint256(keccak256(abi.encode(i, startT))) % 3000);
            if (i % 97 == 96) gap = 50 hours;
            t += gap;
            feed.push(int256(140e8) + int256(i % 7) * 1e7, t);
        }
    }

    function test_window_is_the_calibrated_one() public pure {
        assertEq(VolRing.N, uint256(FeedVol.WINDOW));
    }

    function test_cold_sync_equals_the_walk() public {
        seed(350, 1_700_000_000);
        ring.sync(address(feed));
        assertEq(ring.count(), 290);
        assertEq(ring.sigma(DEV), FeedVol.sigma(address(feed), DEV));
    }

    function test_incremental_sync_equals_the_walk() public {
        uint256 t = seed(350, 1_700_000_000);
        ring.sync(address(feed));
        seed(7, t);
        uint256 gas = gasleft();
        ring.sync(address(feed));
        gas -= gasleft();
        emit log_named_uint("gas: sync of 7 new rounds", gas);
        assertEq(ring.sigma(DEV), FeedVol.sigma(address(feed), DEV));
        assertEq(ring.lastRound(), feed.latest());
    }

    function test_far_behind_rebuilds_and_still_agrees() public {
        uint256 t = seed(300, 1_700_000_000);
        ring.sync(address(feed));
        seed(400, t);
        ring.sync(address(feed));
        assertEq(ring.count(), 290);
        assertEq(ring.sigma(DEV), FeedVol.sigma(address(feed), DEV));
    }

    function test_young_feed_agrees_with_the_walk() public {
        seed(40, 1_700_000_000);
        ring.sync(address(feed));
        assertEq(ring.count(), 39);
        assertEq(ring.sigma(DEV), FeedVol.sigma(address(feed), DEV));
    }

    function test_sync_with_nothing_new_is_a_read() public {
        seed(300, 1_700_000_000);
        ring.sync(address(feed));
        int256 before = ring.sigma(DEV);
        uint256 gas = gasleft();
        ring.sync(address(feed));
        gas -= gasleft();
        assertEq(ring.sigma(DEV), before);
        assertLt(gas, 20_000);
    }

    function test_empty_ring_reverts_like_the_walk() public {
        vm.expectRevert(FeedVol.TooFewRounds.selector);
        ring.sigma(DEV);
    }

    /// The reason for the ring: a purchase priced over the whole window for a
    /// fraction of what walking it cost.
    function test_buy_prices_over_the_window_cheaply() public {
        uint256 t = seed(300, 1_700_000_000);
        vm.warp(t + 60);
        MockPlain usdg = new MockPlain();
        MockHoodStock spcx = new MockHoodStock("SpaceX", "SPCX");
        OptionHouse.Market[] memory ms = new OptionHouse.Market[](1);
        ms[0] = OptionHouse.Market(address(spcx), address(feed), int64(DEV), 3000);
        OptionHouse house = new OptionHouse(address(usdg), ms);

        address writer = address(0xA11CE);
        address buyer = address(0xB111);
        spcx.mintTo(writer, 1e18);
        usdg.mintTo(buyer, 1_000_000e18);
        vm.prank(writer); spcx.approve(address(house), 1e18);
        vm.prank(buyer); usdg.approve(address(house), type(uint256).max);

        vm.prank(writer);
        uint256 id = house.write(0, uint96(139e8), uint40(block.timestamp + 1 hours));

        // a few rounds arrive between the write and the purchase
        seed(3, t);
        vm.warp(block.timestamp + 20 minutes);

        uint256 gas = gasleft();
        vm.prank(buyer);
        house.buy(id, type(uint256).max);
        gas -= gasleft();
        emit log_named_uint("gas: buy after 3 new rounds", gas);
        assertLt(gas, 400_000);

        // priced at the walk's number, over every round published by then
        assertEq(house.vol(0), FeedVol.sigma(address(feed), DEV));
    }
}
