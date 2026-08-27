// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OptionHouse} from "./OptionHouse.sol";
import {IAggregator} from "./FeedVol.sol";

/// The other half of an options market: somewhere for the shares to come from.
///
/// Writing a call means escrowing a whole share, which at these prices is a
/// $138 to $930 ticket. That is the reason a board can carry seventeen live
/// quotes and nothing to buy. Here depositors pool their shares instead: the
/// vault holds them, writes calls against them, and hands the premiums back in
/// proportion to what each person put in. Nobody has to fund a whole contract
/// alone, and a depositor who already holds the stock is doing nothing with it
/// anyway.
///
/// What a depositor gives up is stated rather than buried: if the stock closes
/// above the strike, the part above it goes to whoever bought the call. That is
/// the trade a covered call is, and it is the whole of the risk here. There is
/// no leverage, no borrowing, and no way for the vault to owe more than it
/// holds.
///
/// Shares in the vault are an ERC-20, so a depositor can leave by selling them
/// even while calls are open. Withdrawing the underlying is only possible from
/// what is not currently escrowed, because an escrowed share belongs to a
/// written option until it settles.
contract CoveredCallVault is ERC20 {
    using SafeERC20 for IERC20;

    OptionHouse public immutable house;
    IERC20 public immutable stock;
    IERC20 public immutable usdg;
    address public immutable feed;
    uint32 public immutable marketId;

    /// Who may write and settle on the vault's behalf. Holds no custody: every
    /// path moves assets only between the vault and the house.
    address public keeper;
    address public immutable owner;

    /// Options this vault has written and not yet settled.
    uint256[] public openSeries;
    /// Premiums per vault share ever earned, scaled.
    uint256 public accPerShare;
    mapping(address => uint256) public settledAt;
    mapping(address => uint256) public owed;

    uint256 private constant PRECISION = 1e30;

    event Deposited(address indexed who, uint256 shares);
    event Withdrawn(address indexed who, uint256 stockOut);
    event Wrote(uint256 indexed seriesId, uint96 strike, uint40 expiry);
    event Collected(uint256 premium, uint256 perShare);
    event Claimed(address indexed who, uint256 amount);

    error NotKeeper();
    error NotOwner();
    error NothingToDeposit();
    error NotEnoughFree();
    error TooManyOpen();
    error PremiumTooThin();

    constructor(OptionHouse house_, uint32 marketId_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        house = house_;
        marketId = marketId_;
        (address stock_, address feed_,,) = house_.markets(marketId_);
        stock = IERC20(stock_);
        feed = feed_;
        usdg = house_.usdg();
        owner = msg.sender;
        keeper = msg.sender;
    }

    function setKeeper(address k) external {
        if (msg.sender != owner) revert NotOwner();
        keeper = k;
    }

    // --- depositors -------------------------------------------------------

    /// Put shares in, take vault shares out, one for one with what arrived.
    function deposit(uint256 amount) external {
        if (amount == 0) revert NothingToDeposit();
        _settle(msg.sender);
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stock.balanceOf(address(this)) - before;
        _mint(msg.sender, received);
        emit Deposited(msg.sender, received);
    }

    /// Take shares back out of what is not escrowed in a live option.
    function withdraw(uint256 amount) external {
        _settle(msg.sender);
        if (amount > free()) revert NotEnoughFree();
        _burn(msg.sender, amount);
        stock.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// Stock sitting here rather than escrowed against a written call.
    function free() public view returns (uint256) {
        return stock.balanceOf(address(this));
    }

    /// Premiums owed to `who`, in USDG.
    function claimable(address who) public view returns (uint256) {
        uint256 since = accPerShare - settledAt[who];
        return owed[who] + (balanceOf(who) * since) / PRECISION;
    }

    function claim() external {
        _settle(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) return;
        owed[msg.sender] = 0;
        usdg.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // --- the keeper's two verbs ------------------------------------------

    /// The floor under any premium this vault will accept, in bps of spot.
    ///
    /// Backtested over every feed's history (scripts/11-backtest.mjs), the only
    /// writes that lose money are the ones sold for almost nothing: a quiet
    /// feed reads as low volatility, the premium comes out at pennies, and one
    /// rally hands over more upside than dozens of those pennies covered.
    /// Refusing them removed the entire loss pattern and multiplied the net
    /// per write. So the refusal is written here, where a depositor can read
    /// it, rather than left to the keeper's judgement.
    uint256 public constant MIN_PREMIUM_BPS = 10;

    /// Write one call against a free share and put it on the board.
    function write(uint96 strike, uint40 expiry) external returns (uint256 id) {
        if (msg.sender != keeper) revert NotKeeper();
        if (openSeries.length >= 64) revert TooManyOpen();
        stock.forceApprove(address(house), 1e18);
        id = house.write(marketId, strike, expiry);

        // The house quotes in the same units it charges, spot comes from the
        // feed at 1e8; both sides land on premium-per-spot in bps.
        (uint256 premium,) = house.quote(id);
        (, int256 spot,,,) = IAggregator(feed).latestRoundData();
        if (premium * 10_000 < (uint256(spot) / 100) * MIN_PREMIUM_BPS) revert PremiumTooThin();

        openSeries.push(id);
        emit Wrote(id, strike, expiry);
    }

    /// Settle an expired option and fold whatever came back into the vault.
    function settle(uint256 index, uint80 roundId) external {
        uint256 id = openSeries[index];
        house.settle(id, roundId);
        openSeries[index] = openSeries[openSeries.length - 1];
        openSeries.pop();
        _collect();
    }

    /// Move any USDG that has arrived into the per-share running total. Anyone
    /// may call it; premiums land here from the house when a call is bought.
    function collect() public {
        _collect();
    }

    function _collect() private {
        uint256 supply = totalSupply();
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

    /// USDG already counted into accPerShare and therefore spoken for.
    uint256 private _unclaimed;

    function _settle(address who) private {
        uint256 acc = accPerShare;
        uint256 last = settledAt[who];
        if (acc == last) return;
        owed[who] += (balanceOf(who) * (acc - last)) / PRECISION;
        settledAt[who] = acc;
    }

    /// Both sides settle before balances move, so premiums earned are earned.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
        super._update(from, to, value);
    }

    function openCount() external view returns (uint256) { return openSeries.length; }
}
