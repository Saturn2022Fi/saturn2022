// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {VolOracle} from "../src/VolOracle.sol";

/// The oracle has no constructor arguments and no owner. Deploy, then anyone
/// registers feeds.
contract DeployVolOracle is Script {
    function run() external {
        vm.startBroadcast();
        VolOracle oracle = new VolOracle();
        vm.stopBroadcast();
        console.log("VolOracle", address(oracle));
    }
}
