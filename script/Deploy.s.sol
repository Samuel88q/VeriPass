// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ETHCaliTicketValidator} from "../src/ETHCaliTicketValidator.sol";

contract Deploy is Script {
    function run() external returns (ETHCaliTicketValidator validator) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        validator = new ETHCaliTicketValidator();
        vm.stopBroadcast();
    }
}
