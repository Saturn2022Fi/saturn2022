// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeedVol, IAggregator} from "./FeedVol.sol";
import {VolRing} from "./VolRing.sol";

/// Volatility for any Chainlink feed, from the feed alone.
///
/// Point it at a feed and it answers with that asset's annualized volatility.
/// Nothing is configured and nobody reports: a deviation-threshold feed writes
/// a round when the price has moved by its threshold, so the feed's own
/// history holds both numbers the estimate needs. The threshold is the median
/// move between consecutive rounds, measured here at registration. The
/// volatility is the passage-time estimate over the last WINDOW rounds
/// (FeedVol), kept as a ring (VolRing) so the read is cheap.
///
/// Registration is open to anyone and happens once per feed. After that,
/// `vol` is always current: it reads the ring and, in the same call, walks
/// forward over any rounds the feed has published since the ring was last
/// synced, without writing. Nobody has to keep it fresh for it to be fresh.
/// Anyone may `sync` to fold those rounds in and make the next read cheaper.
///
/// There is no price in any of this a caller could push. The inputs are the
/// times at which Chainlink's nodes chose to publish, and no pool, loan, or
/// trade moves those.
contract VolOracle {
    using VolRing for VolRing.State;

    int256 internal constant ONE = 1e18;
    /// Same window the estimate is calibrated at; the threshold is measured
    /// over it too, so both numbers describe the same stretch of the feed.
    uint80 internal constant WINDOW = FeedVol.WINDOW;
    /// A threshold read off fewer rounds than this is a guess. A feed this
    /// young is registered later, when it has the history.
    uint256 internal constant MIN_ROUNDS = 30;

    mapping(address => VolRing.State) internal rings;
    /// The feed's measured publish threshold, 1e18 based. Zero until registered.
    mapping(address => int256) public deviation;

    event Registered(address indexed feed, int256 deviation, uint256 rounds);

    error AlreadyRegistered();
    error NotRegistered();

    /// Measure the feed's threshold, build its ring, and start answering.
    /// One walk over the window serves both.
    function register(address feed) external {
        if (deviation[feed] != 0) revert AlreadyRegistered();
        (uint80 latest, uint256 tLatest, uint32[] memory gaps, uint256 g, int256 d, uint256 n) = walk(feed);
        deviation[feed] = d;
        rings[feed].fill(gaps, g, latest, tLatest);
        emit Registered(feed, d, n);
    }

    /// Fold the rounds published since the last sync into the ring.
    function sync(address feed) external {
        if (deviation[feed] == 0) revert NotRegistered();
        rings[feed].sync(feed);
    }

    /// Annualized volatility, 1e18, over the feed's last WINDOW rounds, as of
    /// its latest round. Reads the ring, then walks forward over anything the
    /// feed has published since, so the answer never lags the feed.
    function vol(address feed) external view returns (int256) {
        int256 d = deviation[feed];
        if (d == 0) revert NotRegistered();
        VolRing.State storage s = rings[feed];

        (uint80 latest,,,,) = IAggregator(feed).latestRoundData();
        if (s.count != 0 && latest == s.lastRound) return s.sigma(d);
        if (s.count == 0 || latest < s.lastRound || latest - s.lastRound > VolRing.N) {
            return FeedVol.sigma(feed, d, WINDOW);   // the ring cannot be extended; walk
        }

        // Extend the ring in memory: the same pushes sync would make, unwritten.
        uint256 active = s.active;
        uint256 count = s.count;
        uint256 head = s.head;
        uint256 prevT = s.lastT;
        for (uint80 r = s.lastRound + 1; r <= latest; r++) {
            (bool ok, uint256 t) = VolRing.roundTime(feed, r);
            if (!ok || t == 0 || t <= prevT) return FeedVol.sigma(feed, d, WINDOW);
            uint256 gap = FeedVol.cap(t - prevT);
            if (count == VolRing.N) {
                active -= s.gaps[head];
                head = (head + 1) % VolRing.N;
            } else {
                count++;
            }
            active += gap;
            prevT = t;
        }
        return FeedVol.fromMean(active, count, d);
    }

    /// The feed's publish threshold: the median move between consecutive
    /// rounds over the last WINDOW of them, 1e18 based, and how many rounds
    /// that median was taken over. A move is the price change over the
    /// midpoint of the two prices, which is the log return to second order.
    /// Rounds that repeat a price (heartbeats) carry no move and are skipped.
    function measure(address feed) external view returns (int256 d, uint256 n) {
        (,,,, d, n) = walk(feed);
    }

    /// Walk the window once: the capped gap of every round (newest first, for
    /// the ring) and the median move (for the threshold).
    function walk(address feed)
        private
        view
        returns (uint80 latest, uint256 tLatest, uint32[] memory gaps, uint256 g, int256 d, uint256 n)
    {
        int256 pPrev;
        (latest, pPrev,, tLatest,) = IAggregator(feed).latestRoundData();
        if (tLatest == 0) revert FeedVol.TooFewRounds();
        uint256 tPrev = tLatest;

        gaps = new uint32[](WINDOW);
        int256[] memory moves = new int256[](WINDOW);
        for (uint80 i = 1; i <= WINDOW; i++) {
            (bool ok, int256 p, uint256 t) = round(feed, latest - i);
            if (!ok || t == 0 || t >= tPrev) break;   // history ends, or is not ordered
            gaps[g++] = uint32(FeedVol.cap(tPrev - t));
            if (p > 0 && pPrev > 0) {
                int256 diff = pPrev > p ? pPrev - p : p - pPrev;
                int256 m = (diff * ONE * 2) / (pPrev + p);
                if (m > 0) moves[n++] = m;
            }
            pPrev = p;
            tPrev = t;
        }
        if (n < MIN_ROUNDS) revert FeedVol.TooFewRounds();

        d = select(moves, n, n / 2);
    }

    /// The k-th smallest of the first n entries, by Hoare partition: linear
    /// in expectation, where a sort of the same window cost more gas than the
    /// walk that produced it. Reorders the array.
    function select(int256[] memory a, uint256 n, uint256 k) private pure returns (int256) {
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            int256 pivot = a[(lo + hi) / 2];
            uint256 i = lo;
            uint256 j = hi;
            while (i <= j) {
                while (a[i] < pivot) i++;
                while (a[j] > pivot) j--;
                if (i > j) break;
                (a[i], a[j]) = (a[j], a[i]);
                i++;
                if (j == 0) break;
                j--;
            }
            if (k <= j) hi = j;
            else if (k >= i) lo = i;
            else return a[k];
        }
        return a[k];
    }

    /// How many rounds the ring holds and the newest one in it.
    function ring(address feed) external view returns (uint16 count, uint80 lastRound, uint40 lastT) {
        VolRing.State storage s = rings[feed];
        return (s.count, s.lastRound, s.lastT);
    }

    function round(address feed, uint80 id) private view returns (bool ok, int256 p, uint256 t) {
        try IAggregator(feed).getRoundData(id) returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            return (true, answer, updatedAt);
        } catch {
            return (false, 0, 0);
        }
    }
}
