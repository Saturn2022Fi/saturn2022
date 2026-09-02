// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeedVol, IAggregator} from "./FeedVol.sol";

/// The volatility window, kept rather than re-read.
///
/// FeedVol.sigma is the right number and the wrong cost: every call walks the
/// last 290 rounds of a feed, and a buyer paying that walk inside buy() was
/// paying more in gas than the option cost. The walk answers the same
/// question every time, over a window that only ever changes by the rounds
/// published since the last look. So the window lives here: a ring of the
/// last WINDOW capped gaps and their running sum, per market. Catching it up
/// reads only the rounds that are new. The estimate is FeedVol.fromMean over
/// the ring, so it is the same number the walk would produce, to the wei.
///
/// Anyone may sync a market, and the house does it inside write and buy, so
/// a premium is still computed at the moment of purchase over every round the
/// feed has published by then. What changed is only the price of computing it.
library VolRing {
    /// Same window FeedVol was calibrated at. A test pins the two together.
    uint256 internal constant N = 290;

    struct State {
        uint80 lastRound;   // the newest round in the ring
        uint40 lastT;       // its timestamp
        uint16 head;        // next slot to write; the oldest gap once the ring is full
        uint16 count;       // gaps held, at most N
        uint32 active;      // sum of the gaps held (N * MAX_ACTIVE_GAP fits with room to spare)
        uint32[N] gaps;
    }

    /// Bring the ring up to the feed's latest round.
    ///
    /// The common case is a handful of new rounds walked forward from the last
    /// one seen. If the ring is empty, has fallen a whole window behind, or the
    /// feed's round ids stop lining up (an aggregator swap starts a new phase),
    /// the ring is rebuilt from the latest round backwards, which is the walk
    /// FeedVol.sigma does, so the two agree from a cold start too.
    function sync(State storage s, address feed) internal {
        (uint80 latest,,, uint256 tLatest,) = IAggregator(feed).latestRoundData();
        if (tLatest == 0) revert FeedVol.TooFewRounds();
        if (s.count != 0 && latest == s.lastRound) return;
        if (s.count == 0 || latest < s.lastRound || latest - s.lastRound > N) {
            rebuild(s, feed, latest, tLatest);
            return;
        }
        uint256 prevT = s.lastT;
        for (uint80 r = s.lastRound + 1; r <= latest; r++) {
            (bool ok, uint256 t) = roundTime(feed, r);
            if (!ok || t == 0 || t <= prevT) {
                rebuild(s, feed, latest, tLatest);
                return;
            }
            push(s, uint32(FeedVol.cap(t - prevT)));
            prevT = t;
        }
        s.lastRound = latest;
        s.lastT = uint40(tLatest);
    }

    /// Annualized vol over the ring, 1e18. Reverts until the ring holds a round.
    function sigma(State storage s, int256 deviation) internal view returns (int256) {
        return FeedVol.fromMean(s.active, s.count, deviation);
    }

    function rebuild(State storage s, address feed, uint80 latest, uint256 tLatest) private {
        uint32[] memory found = new uint32[](N);
        uint256 n = 0;
        uint256 tPrev = tLatest;
        for (uint80 i = 1; i <= N; i++) {
            (bool ok, uint256 t) = roundTime(feed, latest - i);
            if (!ok || t == 0 || t >= tPrev) break;   // history ends, or is not ordered
            found[n++] = uint32(FeedVol.cap(tPrev - t));
            tPrev = t;
        }
        s.head = 0;
        s.count = 0;
        s.active = 0;
        for (uint256 k = n; k > 0; k--) push(s, found[k - 1]);   // oldest first, so eviction is in order
        s.lastRound = latest;
        s.lastT = uint40(tLatest);
    }

    function push(State storage s, uint32 gap) private {
        if (s.count == N) {
            s.active -= s.gaps[s.head];
        } else {
            s.count++;
        }
        s.gaps[s.head] = gap;
        s.active += gap;
        s.head = uint16((uint256(s.head) + 1) % N);
    }

    /// A round's timestamp, or a miss: some proxies revert on a round that
    /// does not exist rather than answering zeros, and both mean the same here.
    function roundTime(address feed, uint80 id) private view returns (bool ok, uint256 t) {
        try IAggregator(feed).getRoundData(id) returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
            return (true, updatedAt);
        } catch {
            return (false, 0);
        }
    }
}
