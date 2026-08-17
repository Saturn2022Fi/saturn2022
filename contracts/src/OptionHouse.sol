// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BlackScholes} from "./BlackScholes.sol";
import {FeedVol, IAggregator} from "./FeedVol.sol";
import {HoodStock} from "./HoodStock.sol";

/// Options on every stock on the chain, out of one contract.
///
/// Nothing here is quoted by anyone. Spot comes from each stock's Chainlink
/// feed, volatility from that feed's own update cadence, the premium from
/// Black-Scholes computed on chain at the moment of purchase. Fully
/// collateralized: writing a call escrows the share, so there is no margin, no
/// liquidation, and no thin-pool oracle to lean on. The one read that moves
/// money is settlement, and pushing that means pushing Chainlink itself.
///
/// Markets are listed by the deployer, because a listing binds a stock to a
/// feed and a wrong binding prices one company's options off another's chart.
/// Everything after listing is permissionless: writing, buying, settling.
contract OptionHouse {
    using SafeERC20 for IERC20;
    using HoodStock for address;

    struct Market {
        address stock;
        address feed;
        int64 deviation;    // the feed's publish threshold, 1e18 based
        uint16 markupBps;   // what the writer charges over the model, in bps
    }

    struct Series {
        uint32 market;
        address writer;
        address buyer;      // zero until sold
        uint96 strike;      // USD, 1e8 like the feed
        uint40 expiry;
        bool settled;
    }

    IERC20 public immutable usdg;
    address public immutable lister;

    /// A ceiling on the markup, so listing cannot become a way to price an
    /// option at anything at all. Doubling the model is already far past what
    /// any quoted market charges.
    uint16 public constant MAX_MARKUP_BPS = 10_000;
    Market[] public markets;
    Series[] public series;

    event Listed(uint32 indexed market, address stock, address feed);
    event Written(uint256 indexed id, uint32 indexed market, uint96 strike, uint40 expiry);
    event Bought(uint256 indexed id, address buyer, uint256 premium, int256 vol);
    event Settled(uint256 indexed id, int256 price, uint256 buyerPaid, uint256 writerPaid);
    event MarkupSet(uint32 indexed market, uint16 markupBps);

    error NotLister();
    error NotYet();
    error AlreadySold();
    error AlreadySettled();
    error Expired();
    error BadSeries();
    error WrongRound();
    error MarkupTooHigh();

    constructor(address usdg_, Market[] memory initial) {
        usdg = IERC20(usdg_);
        lister = msg.sender;
        for (uint256 i = 0; i < initial.length; i++) {
            markets.push(initial[i]);
            emit Listed(uint32(i), initial[i].stock, initial[i].feed);
        }
    }

    function list(address stock, address feed, int64 deviation, uint16 markupBps)
        external
        returns (uint32 id)
    {
        if (msg.sender != lister) revert NotLister();
        if (markupBps > MAX_MARKUP_BPS) revert MarkupTooHigh();
        id = uint32(markets.length);
        markets.push(Market(stock, feed, deviation, markupBps));
        emit Listed(id, stock, feed);
    }

    /// Escrow one full share of the market's stock, name a strike and expiry.
    function write(uint32 market, uint96 strike, uint40 expiry) external returns (uint256 id) {
        if (expiry <= block.timestamp) revert Expired();
        Market memory m = markets[market];
        m.stock.requireMovable();
        IERC20(m.stock).safeTransferFrom(msg.sender, address(this), 1e18);
        id = series.length;
        series.push(Series(market, msg.sender, address(0), strike, expiry, false));
        emit Written(id, market, strike, expiry);
    }

    /// What the option costs right now, and the vol behind that number.
    function quote(uint256 id) public view returns (uint256 premiumUsdg, int256 vol) {
        Series memory s = series[id];
        if (s.writer == address(0)) revert BadSeries();
        if (block.timestamp >= s.expiry) revert Expired();
        Market memory m = markets[s.market];

        (, int256 spot,,,) = IAggregator(m.feed).latestRoundData();
        vol = FeedVol.sigma(m.feed, int256(m.deviation));
        int256 T = int256(uint256(s.expiry) - block.timestamp) * 1e18 / 31_557_600;
        (int256 call,) = BlackScholes.price(
            spot * 1e10, int256(uint256(s.strike)) * 1e10, T, vol
        );

        // The model prices what the price has been doing. An option is sold on
        // what it might do, and a writer who charges exactly the first is handing
        // over the difference for free: measured against quoted markets, this
        // estimator sits below their implied vol, consistently and in one
        // direction. The markup is that gap, named rather than hidden, and it
        // belongs to whoever is carrying the risk.
        premiumUsdg = (uint256(call) * (10_000 + m.markupBps)) / 10_000 / 1e12;
    }

    /// Pay the model price, own the option. The premium is the writer's now.
    function buy(uint256 id) external {
        Series storage s = series[id];
        if (s.buyer != address(0)) revert AlreadySold();
        if (block.timestamp >= s.expiry) revert Expired();
        (uint256 premium, int256 vol) = quote(id);
        s.buyer = msg.sender;
        usdg.safeTransferFrom(msg.sender, s.writer, premium);
        emit Bought(id, msg.sender, premium, vol);
    }

    /// After expiry, split the escrowed share at the price that was in force AT
    /// expiry: the buyer takes max(P - K, 0) / P of it, the writer the rest.
    ///
    /// The settlement round is pinned, not read at call time. Reading the feed
    /// when settle() happens to be called would let whichever side benefits sit
    /// on an expired option and wait for the price to drift their way, a free
    /// extension of the bet. Instead the caller names the round, and the
    /// contract checks it is the LAST round at or before expiry: its timestamp
    /// is not after expiry, and the round after it, if it exists, is. Any
    /// caller, any time, same price.
    function settle(uint256 id, uint80 roundId) external {
        Series storage s = series[id];
        if (s.settled) revert AlreadySettled();
        if (block.timestamp < s.expiry) revert NotYet();
        Market memory m = markets[s.market];

        (, int256 p,, uint256 t,) = IAggregator(m.feed).getRoundData(roundId);
        if (t == 0 || t > s.expiry) revert WrongRound();

        // The next round must land after expiry, or not exist yet. A round
        // published now is timestamped now, and now >= expiry, so a "latest"
        // round at or before expiry stays the last one forever.
        (uint80 latest,,,,) = IAggregator(m.feed).latestRoundData();
        if (roundId < latest) {
            (,,, uint256 tNext,) = IAggregator(m.feed).getRoundData(roundId + 1);
            if (tNext != 0 && tNext <= s.expiry) revert WrongRound();
        }

        s.settled = true;
        uint256 toBuyer = 0;
        if (s.buyer != address(0) && p > int256(uint256(s.strike))) {
            toBuyer = uint256(p - int256(uint256(s.strike))) * 1e18 / uint256(p);
        }
        uint256 toWriter = 1e18 - toBuyer;
        if (toBuyer != 0) IERC20(m.stock).safeTransfer(s.buyer, toBuyer);
        IERC20(m.stock).safeTransfer(s.writer, toWriter);
        emit Settled(id, p, toBuyer, toWriter);
    }

    function marketCount() external view returns (uint256) { return markets.length; }
    function seriesCount() external view returns (uint256) { return series.length; }
}
