// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {VolOracle} from "../src/VolOracle.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

/// Anyone opens a market; what comes out must be a market the house prices
/// from the oracle's threshold, with a vault the keeper can run and a
/// stranger can deposit into, write from, and buy from.
contract OptionFactoryTest is Test {
    OptionFactory factory;
    VolOracle oracle;
    MockPlain usdc;
    MockHoodStock link;
    HistoryFeed feed;
    address keeper = address(0xC4A4);
    address stranger = address(0x5717);
    address buyer = address(0xB0B);

    function setUp() public {
        oracle = new VolOracle();
        usdc = new MockPlain();
        link = new MockHoodStock("Chainlink", "LINK");
        feed = new HistoryFeed();
        int256 p = 12e8; uint256 t = 1_700_000_000;
        for (uint256 i = 0; i < 300; i++) {
            t += 20 minutes + (i % 5) * 7 minutes;
            p += (p * 55) / 10_000 * (i % 2 == 0 ? int256(1) : -1);
            feed.push(p, t);
        }
        vm.warp(t + 60);
        factory = new OptionFactory(address(usdc), oracle, keeper);
    }

    function test_open_lists_registers_and_stands_up_a_vault() public {
        vm.prank(stranger);
        (uint32 id, CoveredCallVault vault) = factory.open(address(link), address(feed));
        assertEq(id, 0);
        (address stock, address f, int64 d, uint16 markup) = factory.house().markets(0);
        assertEq(stock, address(link));
        assertEq(f, address(feed));
        assertEq(int256(d), oracle.deviation(address(feed)), "threshold is the oracle's");
        assertGt(d, 0);
        assertEq(markup, 3000);
        assertEq(vault.keeper(), keeper);
        assertEq(address(vault.house()), address(factory.house()));
        assertEq(vault.symbol(), "sLINK");
        assertEq(factory.vaultCount(), 1);
        assertEq(address(factory.vaults(0)), address(vault));
    }

    function test_open_uses_a_feed_already_registered() public {
        oracle.register(address(feed));
        int256 before = oracle.deviation(address(feed));
        factory.open(address(link), address(feed));
        (,, int64 d,) = factory.house().markets(0);
        assertEq(int256(d), before);
    }

    function test_one_market_per_feed() public {
        factory.open(address(link), address(feed));
        vm.expectRevert(OptionFactory.AlreadyOpen.selector);
        factory.open(address(link), address(feed));
    }

    function test_the_market_works_end_to_end() public {
        (, CoveredCallVault vault) = factory.open(address(link), address(feed));
        OptionHouse house = factory.house();

        // A stranger deposits a whole token; the keeper writes a call an hour out.
        link.mintTo(stranger, 1e18);
        vm.startPrank(stranger);
        link.approve(address(vault), 1e18);
        vault.deposit(1e18);
        vm.stopPrank();
        (, int256 spot,,,) = feed.latestRoundData();
        vm.prank(keeper);
        uint256 id = vault.write(uint96(uint256(spot * 995 / 1000)), uint40(block.timestamp + 1 hours));

        // The house quotes it from the ring, and a buyer pays.
        (uint256 premium, int256 vol) = house.quote(id);
        assertGt(premium, 0);
        assertGt(vol, 0);
        usdc.transfer(buyer, premium);
        vm.startPrank(buyer);
        usdc.approve(address(house), premium);
        house.buy(id, premium);
        vm.stopPrank();
        (,, address who,,,) = house.series(id);
        assertEq(who, buyer);
    }

    function test_only_the_steward_rekeys_and_it_reaches_every_vault() public {
        (, CoveredCallVault vault) = factory.open(address(link), address(feed));
        vm.prank(stranger);
        vm.expectRevert(OptionFactory.NotSteward.selector);
        factory.rekey(stranger);
        factory.rekey(address(0xD00D));
        assertEq(vault.keeper(), address(0xD00D));
        assertEq(factory.keeper(), address(0xD00D));
    }
}
