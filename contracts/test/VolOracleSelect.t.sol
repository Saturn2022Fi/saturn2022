// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VolOracle} from "../src/VolOracle.sol";
import {HistoryFeed} from "./OptionHouse.t.sol";

/// The median the oracle finds must be the median a full sort finds, on any
/// window: random, sorted, reversed, with ties.
contract VolOracleSelectTest is Test {
    VolOracle oracle;

    function setUp() public { oracle = new VolOracle(); }

    /// A feed whose moves are the given sequence, so measure() is the median of it.
    function feedOf(uint256[] memory bps) internal returns (HistoryFeed f) {
        f = new HistoryFeed();
        int256 p = 1_000_000e8; uint256 t = 1_700_000_000;
        f.push(p, t);
        for (uint256 i = 0; i < bps.length; i++) {
            t += 600;
            p += (p * int256(bps[i] % 300 + 1)) / 100_000;   // 0.001% .. 0.3%, always a move
            f.push(p, t);
        }
    }

    function sortedMedian(int256[] memory a) internal pure returns (int256) {
        for (uint256 i = 1; i < a.length; i++) {
            int256 v = a[i]; uint256 j = i;
            while (j > 0 && a[j - 1] > v) { a[j] = a[j - 1]; j--; }
            a[j] = v;
        }
        return a[a.length / 2];
    }

    function moveOf(int256 a, int256 b) internal pure returns (int256) {
        int256 diff = a > b ? a - b : b - a;
        return (diff * 1e18 * 2) / (a + b);
    }

    function check(uint256[] memory bps) internal {
        HistoryFeed f = feedOf(bps);
        (int256 d,) = oracle.measure(address(f));
        uint80 latest = f.latest();
        uint256 n = bps.length < 290 ? bps.length : 290;
        int256[] memory moves = new int256[](n);
        for (uint80 i = 1; i <= n; i++) {
            (, int256 pNew,,,) = f.getRoundData(latest - i + 1);
            (, int256 pOld,,,) = f.getRoundData(latest - i);
            moves[i - 1] = moveOf(pNew, pOld);
        }
        assertEq(d, sortedMedian(moves));
    }

    function testFuzz_median_matches_sort(uint256 seed, uint8 len) public {
        uint256 n = 30 + uint256(len) % 300;
        uint256[] memory bps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) bps[i] = uint256(keccak256(abi.encode(seed, i)));
        check(bps);
    }

    function test_sorted_reversed_and_ties() public {
        uint256[] memory up = new uint256[](300);
        uint256[] memory down = new uint256[](300);
        uint256[] memory tie = new uint256[](300);
        for (uint256 i = 0; i < 300; i++) { up[i] = i; down[i] = 299 - i; tie[i] = i % 3; }
        check(up); check(down); check(tie);
    }
}
