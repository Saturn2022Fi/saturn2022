// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {OptionHouse} from "../src/OptionHouse.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";

/// The same house, on Base, listed against assets that have no options market.
///
/// Nothing in the contracts changes. The house takes a settlement currency and
/// a list of markets, and a market is a token, a feed, that feed's publish
/// threshold, and a markup. On Robinhood Chain those tokens were equities. Here
/// they are ERC-20s, which the house already handles: its pause check is a
/// staticcall that a plain token simply does not answer.
///
/// The thresholds below are measured, not assumed. Each is the median move
/// between 300 consecutive rounds of that feed, taken the morning of the
/// deploy by scratchpad/measure_base.mjs, which is the same statistic the
/// paper measures on the stock feeds.
///
///   HOUSE_KEY=... VAULT_KEY=... forge script script/DeployBase.s.sol \
///     --rpc-url https://base-rpc.publicnode.com --broadcast --slow
contract DeployBase is Script {
    /// Circle's USDC on Base, six decimals, the same shape as USDG.
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// No treasury on this chain, on purpose. SATURN is on Robinhood Chain, so
    /// there is nobody here to stake it and a treasury would only collect fees
    /// no one could claim. The vault reads a zero treasury as a zero fee, so
    /// every cent of every premium goes to the depositors who wrote the calls.
    address constant NO_TREASURY = address(0);
    uint16 constant MARKUP = 3000;

    function markets() internal pure returns (OptionHouse.Market[] memory ms) {
        ms = new OptionHouse.Market[](2);
        // LINK / USD: threshold 0.5307%, a round every 39.8 minutes
        ms[0] = OptionHouse.Market(
            0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196,
            0x17CAb8FE31E32f08326e5E27412894e49B0f9D65,
            5306589599748834,
            MARKUP
        );
        // AAVE / USD: threshold 0.5360%, a round every 30.3 minutes
        ms[1] = OptionHouse.Market(
            0x63706e401c06ac8513145b7687A14804d17f814b,
            0x3d6774EF702A10b20FCa8Ed40FC022f7E4938e07,
            5359532670361711,
            MARKUP
        );
    }

    function run() external {
        vm.startBroadcast(vm.envUint("HOUSE_KEY"));
        OptionHouse house = new OptionHouse(USDC, markets());
        vm.stopBroadcast();
        console2.log("house", address(house));

        vm.startBroadcast(vm.envUint("VAULT_KEY"));
        console2.log("sLINK", address(new CoveredCallVault(house, 0, NO_TREASURY, "Saturn Chainlink Covered Call", "sLINK")));
        console2.log("sAAVE", address(new CoveredCallVault(house, 1, NO_TREASURY, "Saturn Aave Covered Call", "sAAVE")));
        vm.stopBroadcast();
    }
}
