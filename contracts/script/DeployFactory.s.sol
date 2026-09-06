// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {OptionFactory} from "../src/OptionFactory.sol";
import {VolOracle} from "../src/VolOracle.sol";

/// Base: the factory deploys its own house. The keeper is the crank's key;
/// the steward, who can rotate it, is whoever broadcasts this.
contract DeployFactory is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    VolOracle constant ORACLE = VolOracle(0xd533d4C7e2Be05A814458A26fa6a65e2250dcE5c);

    function run() external {
        address keeper = vm.envAddress("KEEPER");
        vm.startBroadcast();
        OptionFactory factory = new OptionFactory(USDC, ORACLE, keeper);
        vm.stopBroadcast();
        console2.log("factory", address(factory));
        console2.log("house", address(factory.house()));
    }
}
