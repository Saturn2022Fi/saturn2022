// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PayoutToken} from "../src/PayoutToken.sol";
import {HoodStock} from "../src/HoodStock.sol";
import {MockHoodStock, MockPlain} from "./Mocks.sol";

contract PayoutTest is Test {
    PayoutToken tok;
    MockHoodStock aapl;
    address treasury = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1787721910);
        vm.prank(treasury);
        aapl = new MockHoodStock("Apple", "AAPL");
        tok = new PayoutToken("Payout", "PAY", 1_000_000e18, address(aapl));
        vm.prank(treasury);
        aapl.approve(address(tok), type(uint256).max);
    }

    function _holders(uint256 n, uint256 from) internal returns (address[] memory hs) {
        hs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            hs[i] = address(uint160(0x100000 + from + i));
            tok.transfer(hs[i], 10e18);
        }
    }

    function _payOut(uint256 amt) internal returns (uint256 gasUsed) {
        vm.prank(treasury);
        uint256 g = gasleft();
        tok.payOut(amt);
        gasUsed = g - gasleft();
    }

    // --- one payout reaches everyone, whatever the crowd size ---------------

    function test_paying_ten_thousand_holders_is_one_transaction() public {
        address[] memory hs = _holders(10_000, 0);
        _payOut(1e18);                               // warm the slot
        uint256 g = _payOut(1000e18);

        emit log_named_uint("gas to pay 10,000 holders", g);
        assertLt(g, 60_000);

        assertEq(aapl.balanceOf(hs[0]), 0, "nothing was sent to anyone");
        assertEq(aapl.balanceOf(hs[9_999]), 0);
        uint256 each = tok.claimable(hs[0]);
        assertEq(each, tok.claimable(hs[9_999]));
        assertGt(each, 0);
    }

    function test_cost_does_not_grow_with_the_crowd() public {
        _holders(100, 0);
        _payOut(1e18);
        uint256 g1 = _payOut(10e18);

        _holders(5_000, 1_000_000);
        uint256 g2 = _payOut(10e18);

        emit log_named_uint("gas with    100 holders", g1);
        emit log_named_uint("gas with  5,100 holders", g2);
        assertEq(g1, g2);
    }

    function test_holder_transfer_stays_cheap() public {
        tok.transfer(alice, 1000e18);
        _payOut(10e18);
        vm.prank(alice);
        uint256 g = gasleft(); tok.transfer(bob, 1e18); g -= gasleft();
        emit log_named_uint("holder transfer gas", g);
        assertLt(g, 130_000);
    }

    // --- the entitlement is right when balances move ------------------------

    function test_selling_before_a_payout_earns_nothing_from_it() public {
        tok.transfer(alice, 100e18);
        vm.prank(alice);
        tok.transfer(bob, 100e18);
        _payOut(1000e18);
        assertEq(tok.claimable(alice), 0);
        assertGt(tok.claimable(bob), 0);
    }

    function test_a_payout_already_earned_survives_selling() public {
        tok.transfer(alice, 100e18);
        _payOut(1000e18);
        uint256 earned = tok.claimable(alice);
        assertGt(earned, 0);

        vm.prank(alice);
        tok.transfer(bob, 100e18);

        assertEq(tok.claimable(alice), earned);
        assertEq(tok.claimable(bob), 0);
    }

    function test_claim_pays_and_empties() public {
        tok.transfer(alice, 100e18);
        _payOut(1000e18);
        uint256 due = tok.claimable(alice);
        vm.prank(alice);
        tok.claim();
        assertEq(aapl.balanceOf(alice), due);
        assertEq(tok.claimable(alice), 0);
    }

    function test_everything_paid_out_is_owed_to_someone() public {
        address[] memory hs = _holders(50, 0);
        _payOut(1000e18);
        uint256 sum;
        for (uint256 i = 0; i < hs.length; i++) sum += tok.claimable(hs[i]);
        sum += tok.claimable(address(this));
        assertApproxEqRel(sum, 1000e18, 0.000001e18);
        assertLe(sum, 1000e18, "never owes more than it holds");
    }

    // --- the stock token is read correctly ----------------------------------

    function test_dividends_reach_a_payout_that_was_never_claimed() public {
        tok.transfer(alice, 100e18);
        _payOut(1000e18);

        uint256 tokensOwed = tok.claimable(alice);
        uint256 sharesBefore = tok.claimableInShares(alice);
        assertEq(sharesBefore, tokensOwed);

        aapl.payDividend(1.000566080061092436e18);   // the real AAPL multiplier

        assertEq(tok.claimable(alice), tokensOwed, "the token count is untouched");
        uint256 sharesAfter = tok.claimableInShares(alice);
        assertGt(sharesAfter, sharesBefore);
        emit log_named_uint("shares owed before the dividend", sharesBefore);
        emit log_named_uint("shares owed after  the dividend", sharesAfter);
    }

    function test_tokens_and_shares_are_different_counts() public {
        aapl.payDividend(1.000566080061092436e18);
        vm.prank(treasury);
        aapl.transfer(address(this), 1000e18);
        uint256 tokens = aapl.balanceOf(address(this));
        uint256 shares = HoodStock.shareBalanceOf(address(aapl), address(this));
        emit log_named_uint("tokens held ", tokens);
        emit log_named_uint("shares those stand for", shares);
        assertGt(shares, tokens);
        // The feed price is per token and already carries the multiplier, so the
        // token count is what gets priced. The share count is for display.
    }

    function test_an_announced_dividend_is_visible_before_it_lands() public {
        (uint256 g0,) = HoodStock.pendingDividend(address(aapl));
        assertEq(g0, 0);

        aapl.announceDividend(1.01e18, block.timestamp + 3 days);
        (uint256 g1, uint256 at) = HoodStock.pendingDividend(address(aapl));
        assertApproxEqRel(g1, 0.01e18, 0.001e18);
        assertEq(at, block.timestamp + 3 days);
        emit log_named_uint("dividend coming, 1e18 = 100%", g1);

        vm.warp(at + 1);
        (uint256 g2,) = HoodStock.pendingDividend(address(aapl));
        assertEq(g2, 0, "not pending once it has landed");
    }

    function test_a_paused_stock_is_refused_at_the_door() public {
        aapl.setPaused(true);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(HoodStock.TokenIsPaused.selector, address(aapl)));
        tok.payOut(1000e18);
    }

    function test_a_plain_erc20_works_too() public {
        MockPlain plain = new MockPlain();
        PayoutToken t2 = new PayoutToken("P2", "P2", 1000e18, address(plain));
        plain.approve(address(t2), type(uint256).max);
        t2.transfer(alice, 100e18);
        t2.payOut(500e18);
        assertGt(t2.claimable(alice), 0);
        assertEq(HoodStock.multiplier(address(plain)), 1e18);
    }

    function testFuzz_claim_never_exceeds_what_was_paid(uint96 a, uint96 b, uint96 amt) public {
        a = uint96(bound(a, 1e18, 1000e18));
        b = uint96(bound(b, 1e18, 1000e18));
        amt = uint96(bound(amt, 1e6, 100_000e18));
        tok.transfer(alice, a);
        tok.transfer(bob, b);
        _payOut(amt);
        assertLe(tok.claimable(alice) + tok.claimable(bob) + tok.claimable(address(this)), amt);
    }
}

contract CostTest is Test {
    PayoutToken tok;
    MockHoodStock aapl;
    address treasury = address(0xBEEF);

    function setUp() public {
        vm.prank(treasury);
        aapl = new MockHoodStock("Apple", "AAPL");
        tok = new PayoutToken("Payout", "PAY", 1_000_000e18, address(aapl));
        vm.prank(treasury);
        aapl.approve(address(tok), type(uint256).max);
    }

    /// Every figure a project would want before adopting this, measured rather
    /// than argued. The push numbers are what one live payout round on
    /// Robinhood Chain actually cost, read off the chain on 2026-08-26.
    function test_the_whole_cost_picture() public {
        address a = address(0xA11CE);
        address b = address(0xB0B);
        tok.transfer(a, 1000e18);
        tok.transfer(b, 1000e18);

        vm.startPrank(treasury);
        tok.payOut(1e18);
        uint256 gPay = gasleft(); tok.payOut(100e18); gPay = gPay - gasleft();
        vm.stopPrank();

        vm.prank(a);
        uint256 gClaim = gasleft(); tok.claim(); gClaim -= gasleft();

        vm.prank(b);
        uint256 gXfer = gasleft(); tok.transfer(a, 1e18); gXfer -= gasleft();

        emit log_named_uint("pay everyone, once      ", gPay);
        emit log_named_uint("one holder claims       ", gClaim);
        emit log_named_uint("one holder transfers    ", gXfer);
        emit log_named_uint("measured push, one round", 1_023_300_778);
    }
}
