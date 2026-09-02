// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {BlackScholes} from "../src/BlackScholes.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

/// Writing an hour out instead of a week out.
///
/// A depositor who does not want a share locked for a week wants the shortest
/// tenor the vault will accept, and the premium floor decides what that is.
/// The floor is a fraction of spot, so it does not move as the tenor shrinks,
/// while an option's time value shrinks with the square root of it: over an
/// hour the whole value of the contract lives inside about 0.7% of spot, which
/// is narrower than the dollar grid the weekly board is drawn on. These tests
/// pin down what survives that, and what the fixed-point math does when T gets
/// four orders of magnitude smaller than the tenors it was written for.
contract ShortTenorTest is Test {
    OptionHouse house;
    CoveredCallVault vault;
    MockHoodStock spcx;
    MockPlain usdg;
    HistoryFeed feed;

    address lp = address(0xA11CE);
    address buyer = address(0xB111);

    int256 constant SPOT = 143.55e8;
    uint256 constant HOUR = 3600;

    function setUp() public {
        vm.warp(1_787_800_000);
        usdg = new MockPlain();
        spcx = new MockHoodStock("SpaceX", "SPCX");
        feed = new HistoryFeed();
        // 66% annualized comes out of rounds this far apart, the same shape the
        // live SPCX feed publishes at.
        for (uint256 i = 0; i < 30; i++) {
            feed.push(SPOT, block.timestamp - (30 - i) * 2400);
        }
        OptionHouse.Market[] memory ms = new OptionHouse.Market[](1);
        ms[0] = OptionHouse.Market(address(spcx), address(feed), 0.005395e18, 0);
        house = new OptionHouse(address(usdg), ms);
        vault = new CoveredCallVault(house, 0, "Vault SPCX", "vSPCX");

        spcx.mintTo(lp, 5e18);
        usdg.mintTo(buyer, 1_000_000e18);
        vm.prank(lp); spcx.approve(address(vault), type(uint256).max);
        vm.prank(buyer); usdg.approve(address(house), type(uint256).max);
        vm.prank(lp); vault.deposit(5e18);
    }

    /// The floor as the vault enforces it, in USDG's six decimals.
    function _floor() internal pure returns (uint256) {
        return (uint256(SPOT) / 100) * 10 / 10_000;
    }

    /// An hour out, half a percent in the money: the setting the crank uses.
    function test_one_hour_write_clears_the_floor() public {
        uint96 strike = uint96(uint256(SPOT) * 9950 / 10_000);
        uint256 id = vault.write(strike, uint40(block.timestamp + HOUR));

        (uint256 premium,) = house.quote(id);
        emit log_named_uint("premium (usdg 6dp)", premium);
        emit log_named_uint("floor   (usdg 6dp)", _floor());
        assertGt(premium, _floor(), "an hour at -0.5% must clear the floor");
        // Six times the floor is the margin that lets spot drift before the
        // transaction lands without the write reverting underneath it.
        assertGt(premium, _floor() * 5, "and clear it with room to spare");
    }

    /// The same hour at the money clears the floor standing still, and stops
    /// clearing it the moment spot slips. This is the whole reason the crank
    /// writes under spot: the strike is fixed off chain, the premium is priced
    /// on chain when the transaction lands, and a one percent gap between those
    /// two moments is enough to have the write refused.
    function test_at_the_money_is_too_tight_to_rely_on() public {
        uint96 strike = uint96(uint256(SPOT));
        uint256 id = vault.write(strike, uint40(block.timestamp + HOUR));
        (uint256 atMoney,) = house.quote(id);
        emit log_named_uint("at the money, standing still", atMoney);
        assertGt(atMoney, _floor(), "at the money clears it standing still");

        // The same fixed strike after spot slips one percent is refused.
        feed.push(SPOT * 99 / 100, block.timestamp);
        vm.expectRevert(bytes4(keccak256("PremiumTooThin()")));
        vault.write(strike, uint40(block.timestamp + HOUR));
    }

    /// The grid the weekly board is drawn on steps clean over an hour's worth
    /// of value, which is why a short tenor writes off it. The vault does not
    /// merely price it low, it refuses to write it at all.
    function test_the_dollar_grid_is_too_coarse_for_an_hour() public {
        // $145 is the nearest listed strike above a $143.55 spot.
        vm.expectRevert(bytes4(keccak256("PremiumTooThin()")));
        vault.write(145e8, uint40(block.timestamp + HOUR));
    }

    /// Every step of an hour-long contract, from writing it to settling it.
    function test_hour_long_contract_round_trip() public {
        uint96 strike = uint96(uint256(SPOT) * 9950 / 10_000);
        uint40 expiry = uint40(block.timestamp + HOUR);
        uint256 id = vault.write(strike, expiry);
        assertEq(vault.free(), 4e18, "the escrowed share left the vault");

        (uint256 premium,) = house.quote(id);
        uint256 before = usdg.balanceOf(address(vault));
        vm.prank(buyer); house.buy(id, type(uint256).max);
        assertEq(usdg.balanceOf(address(vault)) - before, premium, "the vault was paid");

        // An hour later, spot a little higher than the strike.
        vm.warp(expiry + 1);
        feed.push(SPOT * 101 / 100, expiry);
        (uint80 round,,,,) = feed.latestRoundData();
        vault.settle(0, round);

        // The share comes back minus the slice the buyer's upside is worth,
        // never the whole share.
        uint256 back = vault.free() - 4e18;
        emit log_named_uint("share returned (1e18 = whole)", back);
        assertGt(back, 0.9e18, "most of the share comes home");
        assertLt(back, 1e18, "but not all of it, the call finished up");
        assertEq(vault.openCount(), 0);
    }

    /// The fixed point stays sane four orders of magnitude below a week.
    function test_math_holds_at_tiny_tenors() public pure {
        int256 S = 143.55e18;
        int256 sigma = 0.664e18;
        int256 year = 31_557_600;
        int256 last = 0;
        uint256[5] memory secs = [uint256(900), 1800, 3600, 7200, 18000];
        for (uint256 i = 0; i < secs.length; i++) {
            int256 T = int256(secs[i]) * 1e18 / year;
            (int256 call, int256 put) = BlackScholes.price(S, S, T, sigma);
            require(call > 0, "at the money is worth something");
            require(put > 0, "so is the put");
            // Longer is always dearer: a monotonic curve over tenors this small
            // is the sign the approximation has not fallen apart at the low end,
            // where sqrt(T) is a hundredth and the two probabilities it feeds
            // sit a hair either side of a half.
            require(call > last, "premium must grow with the tenor");
            // At the money with no rate, the call and the put are the same
            // contract seen from two sides. They must price identically.
            require(call - put < 1e12 && put - call < 1e12, "put/call parity holds");
            last = call;
        }
    }
}
