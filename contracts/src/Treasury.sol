// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Where the market's fee goes, and who it belongs to.
///
/// Every premium paid on this market leaves a tenth of itself with the vault
/// that wrote the option, and the vault forwards that tenth here. Anyone
/// holding SATURN can stake it and take a share of what arrives, in proportion
/// to what they staked and for as long as they stake it.
///
/// That is the entire relationship between the token and the market. It is one
/// number, set once in each vault, and it moves USDG that options buyers
/// actually paid. Nothing here mints, nothing here promises, and a staker can
/// leave with their tokens at any moment.
///
/// The accounting is the same running-total pattern the vaults use for their
/// depositors: a per-share accumulator that only moves forward, so joining
/// after a payment cannot claim it and leaving does not forfeit what was
/// already earned.
contract Treasury {
    using SafeERC20 for IERC20;

    IERC20 public immutable saturn;
    IERC20 public immutable usdg;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    /// USDG per staked token ever collected, scaled.
    uint256 public accPerShare;
    mapping(address => uint256) public settledAt;
    mapping(address => uint256) public owed;

    /// What is already spoken for, so a fresh arrival can be told apart from it.
    uint256 private _unclaimed;

    uint256 private constant PRECISION = 1e30;

    event Staked(address indexed who, uint256 amount);
    event Unstaked(address indexed who, uint256 amount);
    event Collected(uint256 amount, uint256 perShare);
    event Claimed(address indexed who, uint256 amount);

    error NothingStaked();
    error NotEnoughStaked();

    constructor(IERC20 saturn_, IERC20 usdg_) {
        saturn = saturn_;
        usdg = usdg_;
    }

    /// Fold whatever USDG has arrived into the running total. Anyone may call
    /// it, and stake, unstake and claim all call it first, so a staker never
    /// has to think about it.
    function collect() public {
        uint256 supply = totalStaked;
        if (supply == 0) return;
        uint256 held = usdg.balanceOf(address(this));
        uint256 unclaimed = _unclaimed;
        if (held <= unclaimed) return;
        uint256 fresh = held - unclaimed;
        _unclaimed = held;
        uint256 perShare = (fresh * PRECISION) / supply;
        accPerShare += perShare;
        emit Collected(fresh, perShare);
    }

    /// Move what `who` has earned since their last settle into their balance.
    function _settle(address who) private {
        uint256 since = accPerShare - settledAt[who];
        if (since != 0 && staked[who] != 0) owed[who] += (staked[who] * since) / PRECISION;
        settledAt[who] = accPerShare;
    }

    function stake(uint256 amount) external {
        if (amount == 0) revert NothingStaked();
        collect();
        _settle(msg.sender);
        saturn.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        if (amount > staked[msg.sender]) revert NotEnoughStaked();
        collect();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        saturn.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// USDG owed to `who` right now, including anything that has arrived but
    /// not yet been folded in.
    function claimable(address who) external view returns (uint256) {
        uint256 acc = accPerShare;
        uint256 supply = totalStaked;
        if (supply != 0) {
            uint256 held = usdg.balanceOf(address(this));
            if (held > _unclaimed) acc += ((held - _unclaimed) * PRECISION) / supply;
        }
        return owed[who] + (staked[who] * (acc - settledAt[who])) / PRECISION;
    }

    function claim() external {
        collect();
        _settle(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) return;
        owed[msg.sender] = 0;
        _unclaimed -= amount;
        usdg.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }
}
