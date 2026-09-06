// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
import {VolOracle} from "../src/VolOracle.sol";

/// The factory deploys its own house. SETTLEMENT is the chain's dollar
/// (USDC on Base, USDG on Robinhood Chain), ORACLE the VolOracle already on
/// that chain, KEEPER the crank's key. The steward, who can rotate the
/// keeper, is whoever broadcasts this.
contract DeployFactory is Script {
    function run() external {
        address settlement = vm.envAddress("SETTLEMENT");
        VolOracle oracle = VolOracle(vm.envAddress("ORACLE"));
        address keeper = vm.envAddress("KEEPER");
        vm.startBroadcast();
        OptionFactory factory = new OptionFactory(settlement, oracle, keeper);
        vm.stopBroadcast();
        console2.log("factory", address(factory));
        console2.log("house", address(factory.house()));
    }
}
