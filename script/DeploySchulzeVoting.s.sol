// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SchulzeVoting} from "../src/SchulzeVoting.sol";

contract DeploySchulzeVoting is Script {
    function run() external returns (SchulzeVoting voting) {
        vm.startBroadcast();
        voting = new SchulzeVoting();
        vm.stopBroadcast();
        console2.log("SchulzeVoting deployed at:", address(voting));
    }
}
