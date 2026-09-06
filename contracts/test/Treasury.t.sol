// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// The link between the token and the market, tested as money rather than as a
/// claim: a premium is paid, a tenth of it reaches a staker, and the other nine
/// tenths reach the depositor who put the stock up.
contract TreasuryTest is Test {
    int256 constant SPOT = 143.55e8;
    int256 constant DEV = 0.005395e18;

    OptionHouse house;
    CoveredCallVault vault;
    Treasury treasury;
    MockHoodStock spcx;
    MockPlain usdg;
    MockPlain saturn;
    HistoryFeed feed;

    address lp = address(0xA11CE);        // puts up the stock
    address buyer = address(0xB111);      // buys the option
    address alice = address(0x5A1);       // stakes SATURN
    address bob = address(0x5B2);         // stakes later

    function setUp() public {
        vm.warp(1_787_800_000);
        usdg = new MockPlain();
        saturn = new MockPlain();
        spcx = new MockHoodStock("SpaceX", "SPCX");
        feed = new HistoryFeed();
        for (uint256 i = 0; i < 30; i++) feed.push(SPOT, block.timestamp - (30 - i) * 2400);

        OptionHouse.Market[] memory ms = new OptionHouse.Market[](1);
        ms[0] = OptionHouse.Market(address(spcx), address(feed), int64(DEV), 3000);
        house = new OptionHouse(address(usdg), ms);
        treasury = new Treasury(IERC20(address(saturn)), IERC20(address(usdg)));
        vault = new CoveredCallVault(house, 0, address(treasury), "Vault SPCX", "vSPCX");

        spcx.mintTo(lp, 5e18);
        usdg.mintTo(buyer, 1_000_000e18);
        saturn.mintTo(alice, 300e18);
        saturn.mintTo(bob, 100e18);
        vm.prank(lp); spcx.approve(address(vault), type(uint256).max);
        vm.prank(buyer); usdg.approve(address(house), type(uint256).max);
        vm.prank(alice); saturn.approve(address(treasury), type(uint256).max);
        vm.prank(bob); saturn.approve(address(treasury), type(uint256).max);
        vm.prank(lp); vault.deposit(2e18);
    }

    /// Write one call and sell it. Returns the premium the buyer paid.
    function sellOne() internal returns (uint256 premium) {
        uint256 id = vault.write(uint96(uint256(SPOT) * 11000 / 10_000), uint40(block.timestamp + 7 days));
        (premium,) = house.quote(id);
        vm.prank(buyer); house.buy(id, type(uint256).max);
        vault.collect();
    }

    function test_a_tenth_of_the_premium_reaches_the_treasury() public {
        vm.prank(alice); treasury.stake(100e18);
        uint256 premium = sellOne();

        uint256 fee = premium / 10;
        assertEq(usdg.balanceOf(address(treasury)), fee, "the treasury holds a tenth");
        assertEq(usdg.balanceOf(address(vault)), premium - fee, "the pool keeps the rest");
        assertApproxEqAbs(treasury.claimable(alice), fee, 1, "the only staker is owed all of it");
    }

    function test_a_staker_can_take_it_out() public {
        vm.prank(alice); treasury.stake(100e18);
        uint256 premium = sellOne();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice); treasury.claim();
        assertApproxEqAbs(usdg.balanceOf(alice) - before, premium / 10, 1, "paid in USDG");
        assertEq(treasury.claimable(alice), 0, "and nothing is left owed");
    }

    function test_the_depositor_still_gets_the_rest() public {
        vm.prank(alice); treasury.stake(100e18);
        uint256 premium = sellOne();

        uint256 before = usdg.balanceOf(lp);
        vm.prank(lp); vault.claim();
        assertApproxEqAbs(usdg.balanceOf(lp) - before, premium - premium / 10, 2, "nine tenths to the pool");
    }

    function test_two_stakers_split_by_weight() public {
        vm.prank(alice); treasury.stake(300e18);
        vm.prank(bob); treasury.stake(100e18);
        uint256 premium = sellOne();

        uint256 fee = premium / 10;
        assertApproxEqAbs(treasury.claimable(alice), (fee * 3) / 4, 2, "three quarters");
        assertApproxEqAbs(treasury.claimable(bob), fee / 4, 2, "one quarter");
    }

    /// Joining after the money arrived must not claim it, which is the one way
    /// a fee split like this is usually broken.
    function test_staking_after_a_payment_does_not_share_in_it() public {
        vm.prank(alice); treasury.stake(100e18);
        uint256 premium = sellOne();

        vm.prank(bob); treasury.stake(100e18);
        assertEq(treasury.claimable(bob), 0, "bob arrived after the money");
        assertApproxEqAbs(treasury.claimable(alice), premium / 10, 1, "alice keeps it");
    }

    function test_unstaking_keeps_what_was_already_earned() public {
        vm.prank(alice); treasury.stake(100e18);
        uint256 premium = sellOne();

        vm.prank(alice); treasury.unstake(100e18);
        assertEq(saturn.balanceOf(alice), 300e18, "the tokens come back");
        assertApproxEqAbs(treasury.claimable(alice), premium / 10, 1, "the earnings stay owed");
        vm.prank(alice); treasury.claim();
        assertApproxEqAbs(usdg.balanceOf(alice), premium / 10, 1, "and can still be taken");
    }

    /// With nobody staking, a premium must not be stranded in the treasury with
    /// no owner. It waits there, and the first staker after it does not get it
    /// either: collect only credits what arrives while someone is staked.
    function test_a_premium_with_no_stakers_is_not_handed_to_a_latecomer() public {
        uint256 premium = sellOne();
        assertEq(usdg.balanceOf(address(treasury)), premium / 10, "the fee still left the pool");

        vm.prank(alice); treasury.stake(100e18);
        treasury.collect();
        assertApproxEqAbs(treasury.claimable(alice), premium / 10, 1, "credited on the first collect after staking");
    }

    function test_a_vault_with_no_treasury_keeps_everything() public {
        CoveredCallVault plain = new CoveredCallVault(house, 0, address(0), "No fee", "nf");
        spcx.mintTo(lp, 2e18);
        vm.prank(lp); spcx.approve(address(plain), type(uint256).max);
        vm.prank(lp); plain.deposit(2e18);

        uint256 id = plain.write(uint96(uint256(SPOT) * 11000 / 10_000), uint40(block.timestamp + 7 days));
        (uint256 premium,) = house.quote(id);
        vm.prank(buyer); house.buy(id, type(uint256).max);
        plain.collect();

        assertEq(usdg.balanceOf(address(plain)), premium, "no fee taken");
    }
}
