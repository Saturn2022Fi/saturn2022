// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HoodStock} from "./HoodStock.sol";

/// A token that pays its holders without ever sending them anything.
///
/// The usual way to hand assets to every holder is to send them: one transfer
/// per holder per asset per round. That cost grows with the holder count while
/// the payout does not, so the more people hold the token, the smaller the
/// share that survives the handing out.
///
/// Here a payout writes one number. Nothing moves until a holder asks, and a
/// holder who never asks costs nothing. Ten holders and ten thousand holders
/// cost the same to pay.
///
/// An entitlement cannot be a stored figure per holder, because balances move.
/// It is a difference: the contract keeps a running total of payout per token
/// ever made, and each holder keeps the value that total had when they were
/// last settled. What they are owed is the gap between the two, times what they
/// held across it. Settlement happens inside every transfer, so the gap is
/// always measured over a period the holder actually held through.
///
/// One asset, deliberately. An earlier build let a project pay out any number
/// of assets and kept a running total for each. Paying stayed cheap, but every
/// holder then carried the whole list on every transfer: with eighteen assets a
/// transfer cost 1,557,692 gas against 97,167 with one. The cost had not gone
/// away, it had moved onto the people the token is for. So the payout asset is
/// fixed here and a transfer touches exactly one running total, whatever the
/// project goes on to buy with it.
contract PayoutToken is ERC20 {
    using SafeERC20 for IERC20;
    using HoodStock for address;

    uint256 private constant PRECISION = 1e30;

    /// What holders are paid in. Fixed at construction, so a transfer can never
    /// come to cost more than it did on the first day.
    address public immutable payoutAsset;

    /// Payout per token ever made, scaled by PRECISION.
    uint256 public accPerToken;
    /// What `accPerToken` read the last time an account was settled.
    mapping(address account => uint256) public settledAt;
    /// Owed and not yet taken.
    mapping(address account => uint256) public owed;

    event PaidOut(uint256 amount, uint256 perToken);
    event Claimed(address indexed account, uint256 amount);

    error NothingHeld();
    error NothingToPayOut();

    constructor(string memory name_, string memory symbol_, uint256 supply, address asset)
        ERC20(name_, symbol_)
    {
        payoutAsset = asset;
        _mint(msg.sender, supply);
    }

    /// Hand `amount` to every holder at once.
    ///
    /// No holder is touched and no list is walked, so this costs the same
    /// whatever the holder count.
    function payOut(uint256 amount) external {
        if (amount == 0) revert NothingToPayOut();
        uint256 supply = totalSupply();
        if (supply == 0) revert NothingHeld();

        // A paused stock token cannot be moved later, so it is refused now
        // rather than promised and then withheld at claim time.
        payoutAsset.requireMovable();

        // Measure what actually arrived, rather than what was asked for.
        uint256 before = IERC20(payoutAsset).balanceOf(address(this));
        IERC20(payoutAsset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(payoutAsset).balanceOf(address(this)) - before;

        uint256 perToken = (received * PRECISION) / supply;
        accPerToken += perToken;
        emit PaidOut(received, perToken);
    }

    /// What `account` may take right now, in tokens.
    function claimable(address account) public view returns (uint256) {
        uint256 since = accPerToken - settledAt[account];
        return owed[account] + (balanceOf(account) * since) / PRECISION;
    }

    /// The same figure counted in shares. A payout left unclaimed keeps earning
    /// its dividends, and this is where that shows up: the token count does not
    /// move, what each token stands for does. For the dollar value, price the
    /// token count against the feed, which already carries the multiplier.
    function claimableInShares(address account) external view returns (uint256) {
        return payoutAsset.toShares(claimable(account));
    }

    function claim() external {
        _settle(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) return;
        owed[msg.sender] = 0;
        IERC20(payoutAsset).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// Move what has accrued since last time into a fixed figure, so a later
    /// balance change cannot rewrite what was already earned.
    function _settle(address account) private {
        uint256 acc = accPerToken;
        uint256 last = settledAt[account];
        if (acc == last) return;
        owed[account] += (balanceOf(account) * (acc - last)) / PRECISION;
        settledAt[account] = acc;
    }

    /// Both sides of a transfer settle first, so a holder is credited for
    /// exactly the period they held through, and moving tokens can neither
    /// create nor destroy an entitlement.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
        super._update(from, to, value);
    }
}
