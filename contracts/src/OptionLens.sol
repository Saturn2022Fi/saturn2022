// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlackScholes} from "./BlackScholes.sol";
import {FeedVol, IAggregator} from "./FeedVol.sol";

/// One eth_call, no account, no gas: the price of an option on a real stock,
/// computed entirely on chain from the stock's Chainlink feed. Spot is the
/// feed's answer; volatility is derived from the feed's own update cadence;
/// the rest is Black-Scholes in fixed point. Nothing off chain is consulted.
contract OptionLens {
    /// strikeBps: strike as basis points of spot (11000 = 10% out of the money).
    /// tenorDays: days to expiry. deviation: the feed's publish threshold, 1e18.
    function quote(address feed, int256 deviation, uint256 strikeBps, uint256 tenorDays)
        external
        view
        returns (int256 spot, int256 vol, int256 callPrice, int256 putPrice)
    {
        (, int256 answer,,,) = IAggregator(feed).latestRoundData();
        spot = answer * 1e10;                                   // 1e8 -> 1e18
        vol = FeedVol.sigma(feed, deviation);
        int256 strike = (spot * int256(strikeBps)) / 10_000;
        int256 T = int256(tenorDays) * 1e18 / 365;
        (callPrice, putPrice) = BlackScholes.price(spot, strike, T, vol);
    }
}
