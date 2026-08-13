// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CoveredCall} from "../src/CoveredCall.sol";
import {FeedVol} from "../src/FeedVol.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";

/// A Chainlink aggregator whose history is planted by the test: rounds spaced
/// `spacing` seconds apart, so the timing-based vol comes out to a known value.
contract MockFeed {
    int256 public answer;
    uint256 public spacing;
    uint80 public latest = 500;

    constructor(int256 a, uint256 s) { answer = a; spacing = s; }
    function set(int256 a) external { answer = a; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (latest, answer, 0, block.timestamp, latest);
    }
    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 back = uint256(latest - id) * spacing;
        return (id, answer, 0, block.timestamp - back, id);
    }
}

contract CoveredCallTest is Test {
    MockHoodStock nvda;
    MockPlain usdg6;
    MockFeed feed;
    CoveredCall mkt;
    address writer = address(0xAAA1);
    address buyer = address(0xBBB1);

    function setUp() public {
        vm.warp(1_787_800_000);
        nvda = new MockHoodStock("NVIDIA", "NVDA");
        usdg6 = new MockPlain();
        // NVDA $214.00, feed updating every 101.5 minutes like the real one
        feed = new MockFeed(214e8, 6090);
        // deviation threshold 0.5264% as measured on the live SLV feed
        mkt = new CoveredCall(address(nvda), address(usdg6), address(feed), 0.005264e18);

        nvda.mintTo(writer, 10e18);
        usdg6.mintTo(buyer, 1_000_000e18);
        vm.prank(writer); nvda.approve(address(mkt), type(uint256).max);
        vm.prank(buyer); usdg6.approve(address(mkt), type(uint256).max);
    }

    function test_vol_comes_from_timing_alone() public view {
        int256 sig = FeedVol.sigma(address(feed), 0.005264e18, 24);
        // 6090 s between rounds gives a raw 0.005264 * sqrt(31557600/6090) =
        // 0.3790, and the measured bias is divided out on top: 0.3790 / 0.915.
        assertApproxEqAbs(sig, 0.4142e18, 0.002e18);
    }

    /// The calibration is a constant, so it must scale the answer and nothing else.
    function test_calibration_is_a_constant_factor() public {
        MockFeed calm = new MockFeed(214e8, 24_000);
        MockFeed wild = new MockFeed(214e8, 600);
        int256 a = FeedVol.sigma(address(calm), 0.005264e18, 24);
        int256 b = FeedVol.sigma(address(wild), 0.005264e18, 24);
        // A constant cannot change the ratio between two feeds. The ratio here is
        // sqrt(21600/600) = 6.0 rather than sqrt(24000/600) = 6.32, because the
        // calm feed's 24000 s gaps are longer than the six-hour ceiling and get
        // charged at the ceiling: the market-hours correction, visible.
        assertApproxEqRel(b * 1e18 / a, 6e18, 0.01e18);
    }

    function test_faster_feed_means_higher_vol() public {
        MockFeed calm = new MockFeed(214e8, 24_000);
        MockFeed wild = new MockFeed(214e8, 600);
        int256 a = FeedVol.sigma(address(calm), 0.005264e18, 24);
        int256 b = FeedVol.sigma(address(wild), 0.005264e18, 24);
        emit log_named_int("calm feed (400 min gaps), vol", a / 1e14);
        emit log_named_int("wild feed (10 min gaps),  vol", b / 1e14);
        assertGt(b, a);
    }

    function test_whole_lifecycle_write_quote_buy_settle() public {
        vm.prank(writer);
        uint256 id = mkt.write(230e8, uint40(block.timestamp + 30 days));

        (uint256 premium, int256 vol) = mkt.quote(id);
        emit log_named_uint("premium (USDG, 6 dec)", premium);
        emit log_named_int("vol used (1e14 = bp) ", vol / 1e14);
        assertGt(premium, 0);

        uint256 writerUsdgBefore = usdg6.balanceOf(writer);
        vm.prank(buyer);
        mkt.buy(id);
        assertEq(usdg6.balanceOf(writer), writerUsdgBefore + premium, "premium goes to the writer");

        // NVDA finishes at $250: buyer is owed (250-230)/250 = 8% of the share
        feed.set(250e8);
        vm.warp(block.timestamp + 30 days + 1);
        mkt.settle(id);

        assertEq(nvda.balanceOf(buyer), 0.08e18);
        assertEq(nvda.balanceOf(writer), 9e18 + 0.92e18);
    }

    function test_expires_worthless_writer_keeps_everything() public {
        vm.prank(writer);
        uint256 id = mkt.write(230e8, uint40(block.timestamp + 30 days));
        vm.prank(buyer);
        mkt.buy(id);

        feed.set(220e8);   // under the strike
        vm.warp(block.timestamp + 30 days + 1);
        mkt.settle(id);

        assertEq(nvda.balanceOf(buyer), 0);
        assertEq(nvda.balanceOf(writer), 10e18);
    }

    function test_premium_scales_with_vol() public {
        vm.prank(writer);
        uint256 id = mkt.write(230e8, uint40(block.timestamp + 30 days));
        (uint256 pSlow,) = mkt.quote(id);

        MockFeed fast = new MockFeed(214e8, 600);
        CoveredCall mkt2 = new CoveredCall(address(nvda), address(usdg6), address(fast), 0.005264e18);
        vm.prank(writer); nvda.approve(address(mkt2), type(uint256).max);
        vm.prank(writer);
        uint256 id2 = mkt2.write(230e8, uint40(block.timestamp + 30 days));
        (uint256 pFast,) = mkt2.quote(id2);

        emit log_named_uint("premium, calm market ", pSlow);
        emit log_named_uint("premium, wild market ", pFast);
        assertGt(pFast, pSlow * 3, "a feed updating 10x faster prices the option several times higher");
    }

    function test_unsold_option_settles_back_to_writer() public {
        vm.prank(writer);
        uint256 id = mkt.write(230e8, uint40(block.timestamp + 30 days));
        feed.set(300e8);
        vm.warp(block.timestamp + 31 days);
        mkt.settle(id);
        assertEq(nvda.balanceOf(writer), 10e18, "no buyer, so the whole share returns");
    }

    function test_paused_stock_cannot_be_written() public {
        nvda.setPaused(true);
        vm.prank(writer);
        vm.expectRevert();
        mkt.write(230e8, uint40(block.timestamp + 30 days));
    }

    function test_gas_quote_and_buy() public {
        vm.prank(writer);
        uint256 id = mkt.write(230e8, uint40(block.timestamp + 30 days));
        uint256 g1 = gasleft(); mkt.quote(id); g1 -= gasleft();
        vm.prank(buyer);
        uint256 g2 = gasleft(); mkt.buy(id); g2 -= gasleft();
        emit log_named_uint("gas: quote (BS + vol from feed)", g1);
        emit log_named_uint("gas: buy", g2);
        assertLt(g1, 200_000);   // walking rounds for the market-hours correction costs more than the old end-to-end span
    }
}
