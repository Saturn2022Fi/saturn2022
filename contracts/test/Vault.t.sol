// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

contract VaultTest is Test {
    OptionHouse house;
    CoveredCallVault vault;
    MockHoodStock nvda;
    MockPlain usdg;
    HistoryFeed feed;

    address alice = address(0xA11CE);   // deposits 3 shares
    address bob = address(0xB0B);       // deposits 1 share
    address buyer = address(0xB111);
    uint40 expiry;

    function setUp() public {
        vm.warp(1_787_800_000);
        usdg = new MockPlain();
        nvda = new MockHoodStock("NVIDIA", "NVDA");
        feed = new HistoryFeed();
        for (uint256 i = 0; i < 30; i++) {
            feed.push(int256(214e8), block.timestamp - (30 - i) * 6090);
        }
        OptionHouse.Market[] memory ms = new OptionHouse.Market[](1);
        ms[0] = OptionHouse.Market(address(nvda), address(feed), 0.005264e18, 0);
        house = new OptionHouse(address(usdg), ms);
        vault = new CoveredCallVault(house, 0, "Vault NVDA", "vNVDA");

        nvda.mintTo(alice, 3e18);
        nvda.mintTo(bob, 1e18);
        usdg.mintTo(buyer, 1_000_000e18);
        vm.prank(alice); nvda.approve(address(vault), type(uint256).max);
        vm.prank(bob); nvda.approve(address(vault), type(uint256).max);
        vm.prank(buyer); usdg.approve(address(house), type(uint256).max);

        expiry = uint40(block.timestamp + 30 days);
    }

    function _deposits() internal {
        vm.prank(alice); vault.deposit(3e18);
        vm.prank(bob); vault.deposit(1e18);
    }

    function test_pooling_lets_small_holders_write_together() public {
        _deposits();
        assertEq(vault.totalSupply(), 4e18);
        assertEq(vault.free(), 4e18);

        // one share of the pool goes out as a written call
        uint256 id = vault.write(230e8, expiry);
        assertEq(vault.free(), 3e18, "the escrowed share left the vault");
        assertEq(vault.openCount(), 1);

        vm.prank(buyer);
        house.buy(id);
        vault.collect();

        // premiums split by what each put in: alice three quarters, bob one
        uint256 a = vault.claimable(alice);
        uint256 b = vault.claimable(bob);
        assertGt(a, 0);
        assertApproxEqRel(a, b * 3, 0.0001e18);
        emit log_named_uint("alice premium (USDG)", a);
        emit log_named_uint("bob premium   (USDG)", b);
    }

    function test_premium_actually_pays_out() public {
        _deposits();
        uint256 id = vault.write(230e8, expiry);
        vm.prank(buyer); house.buy(id);
        vault.collect();

        uint256 due = vault.claimable(alice);
        vm.prank(alice); vault.claim();
        assertEq(usdg.balanceOf(alice), due);
        assertEq(vault.claimable(alice), 0);
    }

    function test_escrowed_share_cannot_be_withdrawn() public {
        _deposits();
        vault.write(230e8, expiry);
        // three of four are free; asking for all four fails
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotEnoughFree.selector);
        vault.withdraw(4e18);
        vm.prank(alice);
        vault.withdraw(3e18);            // the free part comes out fine
        assertEq(nvda.balanceOf(alice), 3e18);
    }

    function test_expiry_in_the_money_costs_the_vault_the_upside() public {
        _deposits();
        uint256 id = vault.write(230e8, expiry);
        vm.prank(buyer); house.buy(id);

        feed.push(280e8, expiry - 10);   // closes above the strike
        uint80 last = feed.latest();
        vm.warp(uint256(expiry) + 1);
        vault.settle(0, last);

        // the vault gets back only what the option did not take
        uint256 taken = uint256(280e8 - 230e8) * 1e18 / 280e8;
        assertEq(vault.free(), 4e18 - taken);
        assertEq(nvda.balanceOf(buyer), taken, "the buyer took the upside");
        assertEq(vault.openCount(), 0);
    }

    function test_expiry_out_of_the_money_returns_everything() public {
        _deposits();
        uint256 id = vault.write(230e8, expiry);
        vm.prank(buyer); house.buy(id);
        vault.collect();

        feed.push(220e8, expiry - 10);   // under the strike
        uint80 last = feed.latest();
        vm.warp(uint256(expiry) + 1);
        vault.settle(0, last);

        assertEq(vault.free(), 4e18, "the whole share came home");
        assertGt(vault.claimable(alice), 0, "and the premium stayed earned");
    }

    function test_joining_after_a_premium_does_not_share_in_it() public {
        _deposits();
        uint256 id = vault.write(230e8, expiry);
        vm.prank(buyer); house.buy(id);
        vault.collect();
        uint256 aliceBefore = vault.claimable(alice);

        address carol = address(0xCAC0);
        nvda.mintTo(carol, 5e18);
        vm.prank(carol); nvda.approve(address(vault), type(uint256).max);
        vm.prank(carol); vault.deposit(5e18);

        assertEq(vault.claimable(carol), 0, "latecomers earn nothing retroactively");
        assertEq(vault.claimable(alice), aliceBefore, "and take nothing from the earlier ones");
    }

    function test_refuses_to_sell_for_pennies() public {
        _deposits();
        // Deep out of the money and short-dated: the model prices this call at
        // fractions of a cent on a $214 stock. The backtest found every losing
        // write looks exactly like this, so the vault must refuse it.
        vm.expectRevert(CoveredCallVault.PremiumTooThin.selector);
        vault.write(500e8, uint40(block.timestamp + 1 days));
        assertEq(vault.free(), 4e18, "the share never left");
        assertEq(vault.openCount(), 0);
    }

    function test_only_keeper_writes() public {
        _deposits();
        vm.prank(alice);
        vm.expectRevert(CoveredCallVault.NotKeeper.selector);
        vault.write(230e8, expiry);
    }

    function test_vault_shares_move_with_their_earnings() public {
        _deposits();
        uint256 id = vault.write(230e8, expiry);
        vm.prank(buyer); house.buy(id);
        vault.collect();

        uint256 aliceEarned = vault.claimable(alice);
        vm.prank(alice);
        vault.transfer(bob, 3e18);      // alice sells out entirely

        assertEq(vault.claimable(alice), aliceEarned, "what she earned stays hers");
        assertEq(vault.balanceOf(bob), 4e18);
    }
}
