// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";
import {HTLCCoordinator} from "../src/HTLCCoordinator.sol";

contract DeployHTLCCoordinator is Script {
    function run() external {
        uint256 deployerPrivateKey;

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            uint32 index = uint32(vm.envOr("DERIVATION_INDEX", uint256(0)));
            deployerPrivateKey = vm.deriveKey(mnemonic, index);
        } else {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        }

        vm.startBroadcast(deployerPrivateKey);

        HTLCErc20 htlc = new HTLCErc20();
        console.log("HTLCErc20 deployed at:", address(htlc));

        HTLCCoordinator coordinator = new HTLCCoordinator(address(htlc));
        console.log("HTLCCoordinator deployed at:", address(coordinator));

        vm.stopBroadcast();
    }
}
