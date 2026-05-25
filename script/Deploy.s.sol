// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CopelandVoting} from "../src/CopelandVoting.sol";

contract DeployCopelandVoting is Script {
    function run() external returns (CopelandVoting voting) {
        vm.startBroadcast();
        voting = new CopelandVoting();
        vm.stopBroadcast();
        console2.log("CopelandVoting deployed at:", address(voting));
    }
}
