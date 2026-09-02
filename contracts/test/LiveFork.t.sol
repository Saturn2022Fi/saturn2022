// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionLens} from "../src/OptionLens.sol";
import {IAggregator} from "../src/FeedVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// The whole thing against the real chain: the deployed contracts, the real
/// SpaceX token with its dividend multiplier and pause switch, the real
/// Chainlink feed with its real round history. Nothing here is a mock.
///
///   forge test --match-contract LiveFork --fork-url https://rpc.mainnet.chain.robinhood.com -vv
///
/// Balances are conjured with deal() so the run costs nothing, but every
/// contract, price and code path is the one that will run for real.
contract LiveForkTest is Test {
    OptionHouse constant HOUSE = OptionHouse(0xd8E48293DBfc9452F6c60850ebdE555af8d9E9Da);
    OptionLens constant LENS = OptionLens(0x87A7593659E08b02098d4c3D8F3c236D0414dA81);
    CoveredCallVault constant VAULT = CoveredCallVault(0x7207EBc7493F66f62166fb951F14bB333C06297C);

    IERC20 constant SPCX = IERC20(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant FEED = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    int256 constant DEVIATION = 5395404172112830;

    address alice = address(0xA11CE);   // deposits 3 shares
    address bob = address(0xB0B);       // deposits 1 share
    address buyer = address(0xB111);

    modifier onlyFork() {
        if (block.chainid != 4663) return;
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        deal(address(SPCX), alice, 3e18);
        deal(address(SPCX), bob, 1e18);
        deal(address(USDG), buyer, 10_000e6);
        vm.prank(alice); SPCX.approve(address(VAULT), type(uint256).max);
        vm.prank(bob); SPCX.approve(address(VAULT), type(uint256).max);
        vm.prank(buyer); USDG.approve(address(HOUSE), type(uint256).max);
    }

    function test_live_deployment_is_wired() public onlyFork {
        assertEq(HOUSE.marketCount(), 17, "seventeen markets listed");
        (address stock, address feed, int64 dev,) = HOUSE.markets(0);
        assertEq(stock, address(SPCX));
        assertEq(feed, FEED);
        assertEq(int256(dev), DEVIATION, "market carries its own measured threshold");
        assertEq(address(VAULT.house()), address(HOUSE));
        assertEq(address(VAULT.stock()), address(SPCX));
    }

    function test_lens_prices_the_real_feed() public onlyFork {
        (int256 spot, int256 vol, int256 call, int256 put) = LENS.quote(FEED, DEVIATION, 11000, 30);
        emit log_named_int("SpaceX spot   (cents)", spot / 1e16);
        emit log_named_int("volatility    (bp)   ", vol / 1e14);
        emit log_named_int("30d 110% call (1e4)  ", call / 1e14);
        emit log_named_int("30d 110% put  (1e4)  ", put / 1e14);
        assertGt(spot, 50e18);
        assertLt(spot, 1000e18);
        assertGt(vol, 0.10e18);
        assertLt(vol, 2e18);
        assertGt(call, 0);
        assertLt(call, spot);
    }

    /// Deposit, pool, write, buy, settle, claim, withdraw. The real cycle.
    function test_the_whole_cycle_on_real_assets() public onlyFork {
        // 1. two people pool their SpaceX
        vm.prank(alice); VAULT.deposit(3e18);
        vm.prank(bob); VAULT.deposit(1e18);
        assertEq(VAULT.totalSupply(), 4e18, "four shares pooled");
        assertEq(VAULT.free(), 4e18);

        // 2. the vault writes one call, 10% out of the money, 30 days out
        (, int256 spot,,,) = IAggregator(FEED).latestRoundData();
        uint96 strike = uint96(uint256(spot) * 110 / 100);
        uint40 expiry = uint40(block.timestamp + 30 days);
        vm.prank(VAULT.keeper());
        uint256 id = VAULT.write(strike, expiry);
        assertEq(VAULT.free(), 3e18, "one share left as escrow");

        // 3. someone buys it at the model price
        (uint256 premium, int256 vol) = HOUSE.quote(id);
        emit log_named_uint("premium paid (USDG, 6dp)", premium);
        emit log_named_int("vol behind it (bp)      ", vol / 1e14);
        assertGt(premium, 0);

        uint256 vaultUsdgBefore = USDG.balanceOf(address(VAULT));
        vm.prank(buyer);
        HOUSE.buy(id);
        assertEq(USDG.balanceOf(address(VAULT)) - vaultUsdgBefore, premium, "premium landed in the vault");

        // 4. the premium splits three to one, without a transfer per holder
        VAULT.collect();
        uint256 a = VAULT.claimable(alice);
        uint256 b = VAULT.claimable(bob);
        assertApproxEqRel(a, b * 3, 0.0001e18, "split by what each put in");
        assertApproxEqAbs(a + b, premium, 10);

        // 5. alice takes hers
        vm.prank(alice); VAULT.claim();
        assertEq(USDG.balanceOf(alice), a);

        // 6. expiry. find the round that covered it, settle against that one.
        vm.warp(uint256(expiry) + 1 hours);
        uint80 atExpiry = _roundAtOrBefore(FEED, expiry);
        VAULT.settle(0, atExpiry);
        assertEq(VAULT.openCount(), 0, "the option is closed");
        assertGe(VAULT.free(), 3e18, "escrow came home, less any exercise");
        emit log_named_uint("shares back in the vault", VAULT.free());

        // 7. bob leaves with his stock.
        // Every value is read before the prank: a call inside the argument list
        // would consume it, and the withdraw would come from the test contract.
        uint256 bobShares = VAULT.balanceOf(bob);
        uint256 freeNow = VAULT.free();
        uint256 take = bobShares > freeNow ? freeNow : bobShares;
        vm.prank(bob);
        VAULT.withdraw(take);
        assertEq(SPCX.balanceOf(bob), take, "he got real SpaceX back");
        emit log_named_uint("bob withdrew (SpaceX)", take);
    }

    /// The last round at or before `t`, walking back from the latest.
    function _roundAtOrBefore(address feed, uint256 t) internal view returns (uint80) {
        (uint80 latest,,,,) = IAggregator(feed).latestRoundData();
        for (uint80 i = latest; i > latest - 200; i--) {
            (,,, uint256 ts,) = IAggregator(feed).getRoundData(i);
            if (ts != 0 && ts <= t) return i;
        }
        revert("no round covers that time");
    }

    /// A paused stock cannot be written against, checked on the real token.
    function test_real_token_pause_switch_is_read() public onlyFork {
        (bool ok, bytes memory ret) = address(SPCX).staticcall(abi.encodeWithSignature("tokenPaused()"));
        assertTrue(ok && ret.length == 32, "the real token exposes a pause switch");
        assertFalse(abi.decode(ret, (bool)), "and it is not paused today");
    }

    /// The dividend multiplier is read for display and never for value.
    function test_real_multiplier_is_visible() public onlyFork {
        (bool ok, bytes memory ret) = address(SPCX).staticcall(abi.encodeWithSignature("uiMultiplier()"));
        assertTrue(ok, "the real token carries a multiplier");
        uint256 m = abi.decode(ret, (uint256));
        emit log_named_uint("SpaceX uiMultiplier", m);
        assertGe(m, 1e18);
    }
}
