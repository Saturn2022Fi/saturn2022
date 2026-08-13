// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BlackScholes} from "./BlackScholes.sol";
import {FeedVol, IAggregator} from "./FeedVol.sol";
import {HoodStock} from "./HoodStock.sol";

/// A call option on a real stock, written, priced, sold and settled entirely
/// on chain. Nothing here is quoted by anyone: the premium comes out of
/// Black-Scholes at the moment of purchase, with spot from the stock's
/// Chainlink feed and volatility from that same feed's update cadence.
///
/// Fully collateralized, deliberately. The writer escrows the whole share, so
/// there is no margin, no liquidation, and no price-manipulation surface: the
/// only oracle read that moves money is the settlement read, and pushing THAT
/// needs the Chainlink feed itself, not a thin pool.
///
/// Cash-settled in the stock. At expiry the buyer's payoff max(P-K, 0) is paid
/// in stock tokens at the settlement price, the writer keeps the rest, and
/// either side can trigger it. An option nobody settles just sits; the stock
/// is never stranded because settle() always partitions the whole escrow.
contract CoveredCall {
    using SafeERC20 for IERC20;
    using HoodStock for address;

    struct Series {
        address writer;
        address buyer;          // zero until sold
        uint96 strike;          // USD, 1e8 like the feed
        uint40 expiry;
        bool settled;
    }

    IERC20 public immutable stock;
    IERC20 public immutable usdg;
    address public immutable feed;
    /// The feed's publish threshold. Public constant of the deployment, not a knob.
    int256 public immutable feedDeviation;

    Series[] public series;

    event Written(uint256 indexed id, uint96 strike, uint40 expiry);
    event Bought(uint256 indexed id, address buyer, uint256 premium, int256 vol);
    event Settled(uint256 indexed id, int256 price, uint256 buyerPaid, uint256 writerPaid);

    error NotYet();
    error AlreadySold();
    error AlreadySettled();
    error Expired();
    error BadSeries();

    constructor(address stock_, address usdg_, address feed_, int256 deviation_) {
        stock = IERC20(stock_);
        usdg = IERC20(usdg_);
        feed = feed_;
        feedDeviation = deviation_;
    }

    /// Escrow one full share, name a strike and an expiry. That is all writing is.
    function write(uint96 strike, uint40 expiry) external returns (uint256 id) {
        if (expiry <= block.timestamp) revert Expired();
        address(stock).requireMovable();
        stock.safeTransferFrom(msg.sender, address(this), 1e18);
        id = series.length;
        series.push(Series(msg.sender, address(0), strike, expiry, false));
        emit Written(id, strike, expiry);
    }

    /// What the option costs right now, and the vol that number was built from.
    function quote(uint256 id) public view returns (uint256 premiumUsdg, int256 vol) {
        Series memory s = series[id];
        if (s.writer == address(0)) revert BadSeries();
        if (block.timestamp >= s.expiry) revert Expired();

        (, int256 spot,, ,) = IAggregator(feed).latestRoundData();      // 1e8
        vol = FeedVol.sigma(feed, feedDeviation, 24);
        int256 T = int256(uint256(s.expiry) - block.timestamp) * 1e18 / 31_557_600;
        (int256 call,) = BlackScholes.price(
            spot * 1e10,                       // 1e8 -> 1e18
            int256(uint256(s.strike)) * 1e10,
            T,
            vol
        );
        premiumUsdg = uint256(call) / 1e12;    // 1e18 USD -> 1e6 USDG
    }

    /// Pay the model price, own the option. The premium goes to the writer now;
    /// it is theirs whatever happens at expiry.
    function buy(uint256 id) external {
        Series storage s = series[id];
        if (s.buyer != address(0)) revert AlreadySold();
        if (block.timestamp >= s.expiry) revert Expired();
        (uint256 premium, int256 vol) = quote(id);
        s.buyer = msg.sender;
        usdg.safeTransferFrom(msg.sender, s.writer, premium);
        emit Bought(id, msg.sender, premium, vol);
    }

    /// After expiry, split the escrowed share by the settlement price:
    /// the buyer takes max(P - K, 0) / P of it, the writer takes the rest.
    function settle(uint256 id) external {
        Series storage s = series[id];
        if (s.settled) revert AlreadySettled();
        if (block.timestamp < s.expiry) revert NotYet();
        s.settled = true;

        (, int256 p,, ,) = IAggregator(feed).latestRoundData();
        uint256 toBuyer = 0;
        if (s.buyer != address(0) && p > int256(uint256(s.strike))) {
            toBuyer = uint256(p - int256(uint256(s.strike))) * 1e18 / uint256(p);
        }
        uint256 toWriter = 1e18 - toBuyer;
        if (toBuyer != 0) stock.safeTransfer(s.buyer, toBuyer);
        stock.safeTransfer(s.writer, toWriter);
        emit Settled(id, p, toBuyer, toWriter);
    }
}
