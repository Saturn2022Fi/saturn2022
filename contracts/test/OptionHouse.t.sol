// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";

/// A feed with a real round history the tests control: each round has its own
/// price and timestamp, so settlement pinning can be exercised properly.
contract HistoryFeed {
    struct R { int256 p; uint256 t; }
    mapping(uint80 => R) public rounds;
    uint80 public latest;

    function push(int256 p, uint256 t) external {
        latest++;
        rounds[latest] = R(p, t);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        R memory r = rounds[latest];
        return (latest, r.p, 0, r.t, latest);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        R memory r = rounds[id];
        return (id, r.p, 0, r.t, id);
    }
}

contract OptionHouseTest is Test {
    OptionHouse house;
    MockHoodStock nvda;
    MockPlain usdg;
    HistoryFeed feed;
    address writer = address(0xAAA1);
    address buyer = address(0xBBB1);
    uint40 expiry;

    function setUp() public {
        vm.warp(1_787_800_000);
        usdg = new MockPlain();
        nvda = new MockHoodStock("NVIDIA", "NVDA");
        feed = new HistoryFeed();
        // a live history: rounds every ~100 minutes before expiry
        for (uint256 i = 0; i < 30; i++) {
            feed.push(int256(214e8) + int256(i) * 1e7, block.timestamp - (30 - i) * 6090);
        }
        OptionHouse.Market[] memory ms = new OptionHouse.Market[](1);
        ms[0] = OptionHouse.Market(address(nvda), address(feed), 0.005264e18, 0);
        house = new OptionHouse(address(usdg), ms);

        nvda.mintTo(writer, 10e18);
        usdg.mintTo(buyer, 1_000_000e18);
        vm.prank(writer); nvda.approve(address(house), type(uint256).max);
        vm.prank(buyer); usdg.approve(address(house), type(uint256).max);

        expiry = uint40(block.timestamp + 30 days);
    }

    function _writeAndBuy(uint96 strike) internal returns (uint256 id) {
        vm.prank(writer);
        id = house.write(0, strike, expiry);
        vm.prank(buyer);
        house.buy(id, type(uint256).max);
    }

    function test_constructor_lists_markets() public view {
        assertEq(house.marketCount(), 1);
    }

    function test_buy_refuses_a_premium_above_the_cap() public {
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        (uint256 premium,) = house.quote(id);
        assertGt(premium, 0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(OptionHouse.PremiumAboveMax.selector, premium, premium - 1));
        house.buy(id, premium - 1);

        vm.prank(buyer);
        house.buy(id, premium);           // exactly what was quoted is enough
        (, , address b, , ,) = house.series(id);
        assertEq(b, buyer);
    }

    function test_writer_cancels_an_unsold_call() public {
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        assertEq(nvda.balanceOf(writer), 9e18, "one share escrowed");

        vm.prank(writer);
        house.cancel(id);
        assertEq(nvda.balanceOf(writer), 10e18, "and it came back");

        // the series is closed: nobody can buy it or settle it now
        vm.prank(buyer);
        vm.expectRevert(OptionHouse.AlreadySettled.selector);
        house.buy(id, type(uint256).max);
        vm.warp(uint256(expiry) + 1);
        uint80 last = feed.latest();
        vm.expectRevert(OptionHouse.AlreadySettled.selector);
        house.settle(id, last);
    }

    function test_cancel_refuses_a_sold_call_and_a_stranger() public {
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        vm.prank(buyer);
        vm.expectRevert(OptionHouse.NotWriter.selector);
        house.cancel(id);

        vm.prank(buyer);
        house.buy(id, type(uint256).max);
        vm.prank(writer);
        vm.expectRevert(OptionHouse.AlreadySold.selector);
        house.cancel(id);
    }

    function test_settles_at_the_expiry_round_not_at_call_time() public {
        uint256 id = _writeAndBuy(230e8);

        // the last round before expiry says $225: out of the money
        feed.push(225e8, expiry - 100);
        uint80 atExpiry = feed.latest();

        // after expiry the stock rips to $300; the buyer waits and settles late
        vm.warp(uint256(expiry) + 3 days);
        feed.push(300e8, block.timestamp - 60);

        house.settle(id, atExpiry);
        // paid at $225, not $300: the option expired worthless
        assertEq(nvda.balanceOf(buyer), 0, "waiting after expiry earns nothing");
        assertEq(nvda.balanceOf(writer), 10e18);
    }

    function test_wrong_round_is_refused() public {
        uint256 id = _writeAndBuy(230e8);
        feed.push(225e8, expiry - 200);
        uint80 early = feed.latest();          // NOT the last one before expiry
        feed.push(280e8, expiry - 100);
        uint80 last = feed.latest();
        vm.warp(uint256(expiry) + 1);
        feed.push(300e8, block.timestamp);     // after expiry

        // an earlier round is refused: a later one exists at or before expiry
        vm.expectRevert(OptionHouse.WrongRound.selector);
        house.settle(id, early);
        // a round after expiry is refused outright
        uint80 late = feed.latest();
        vm.expectRevert(OptionHouse.WrongRound.selector);
        house.settle(id, late);
        // the right one goes through, in the money at $280
        house.settle(id, last);
        assertEq(nvda.balanceOf(buyer), uint256(280e8 - 230e8) * 1e18 / 280e8);
    }

    function test_weekend_expiry_settles_at_friday_close() public {
        uint256 id = _writeAndBuy(230e8);
        // friday close at $250, then the feed sleeps through the weekend
        feed.push(250e8, expiry - 2 hours);
        uint80 friday = feed.latest();
        vm.warp(uint256(expiry) + 60 hours);   // sunday night: no rounds since
        house.settle(id, friday);
        assertEq(nvda.balanceOf(buyer), uint256(250e8 - 230e8) * 1e18 / 250e8);
    }

    function test_unsold_settles_back_to_writer() public {
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        feed.push(300e8, expiry - 10);
        uint80 last = feed.latest();
        vm.warp(uint256(expiry) + 1);
        house.settle(id, last);
        assertEq(nvda.balanceOf(writer), 10e18);
    }

    function test_cannot_settle_twice() public {
        uint256 id = _writeAndBuy(230e8);
        feed.push(250e8, expiry - 10);
        uint80 last = feed.latest();
        vm.warp(uint256(expiry) + 1);
        house.settle(id, last);
        vm.expectRevert(OptionHouse.AlreadySettled.selector);
        house.settle(id, last);
    }

    function test_markup_is_charged_and_bounded() public {
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        (uint256 plain,) = house.quote(id);

        house.setMarkup(0, 2000);                    // twenty percent over the model
        (uint256 marked,) = house.quote(id);
        assertApproxEqRel(marked, plain * 12 / 10, 0.001e18, "the markup lands on the price");
        emit log_named_uint("model price   (USDG)", plain);
        emit log_named_uint("with 20% markup     ", marked);

        // it is bounded, so listing cannot price an option at anything at all
        vm.expectRevert(OptionHouse.MarkupTooHigh.selector);
        house.setMarkup(0, 10_001);

        // and only the lister moves it
        vm.prank(buyer);
        vm.expectRevert(OptionHouse.NotLister.selector);
        house.setMarkup(0, 500);
    }

    function test_a_buyer_pays_the_marked_price() public {
        house.setMarkup(0, 2000);
        vm.prank(writer);
        uint256 id = house.write(0, 230e8, expiry);
        (uint256 due,) = house.quote(id);
        uint256 before = usdg.balanceOf(writer);
        vm.prank(buyer);
        house.buy(id, type(uint256).max);
        assertEq(usdg.balanceOf(writer) - before, due, "the writer keeps the whole marked premium");
    }

    function test_only_lister_lists() public {
        vm.prank(buyer);
        vm.expectRevert(OptionHouse.NotLister.selector);
        house.list(address(nvda), address(feed), 0.005264e18, 0);
    }
}
