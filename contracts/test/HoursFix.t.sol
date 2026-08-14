// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FeedVol} from "../src/FeedVol.sol";

/// What charging for market-open time rather than calendar time does to the
/// estimate, on the live feeds. Run against the chain:
///   forge test --match-contract HoursFix --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract HoursFixTest is Test {
    struct Case { string name; address feed; int256 dev; uint256 marketIv; }

    function test_against_quoted_markets() public {
        if (block.chainid != 4663) return;
        Case[4] memory cs = [
            Case("ORCL", 0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844, 5422538519903522, 70),
            Case("MU",   0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, 5372804508990962, 66),
            Case("SNDK", 0xfb133Fa4B7b385802B693a293606682Df47109A3, 5488052450720371, 79),
            Case("META", 0x7C38C00C30BEe9378381E7B6135d7283356D71b1, 5166862735098046, 34)
        ];
        for (uint256 i = 0; i < cs.length; i++) {
            int256 v = FeedVol.sigma(cs[i].feed, cs[i].dev, 24);
            emit log_named_string("asset", cs[i].name);
            emit log_named_int("  ours (bp)      ", v / 1e14);
            emit log_named_uint("  quoted IV (%)  ", cs[i].marketIv);
            emit log_named_int("  ratio (1e4=1x) ", (v * 100) / int256(cs[i].marketIv) / 1e14);
            assertGt(v, 0.05e18);
            assertLt(v, 3e18);
        }
    }
}
