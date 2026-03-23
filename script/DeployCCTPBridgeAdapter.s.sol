// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CCTPBridgeAdapter} from "../src/CCTPBridgeAdapter.sol";

contract DeployCCTPBridgeAdapter is Script {
    // CCTP V2 TokenMessenger (same address on all EVM chains)
    address constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    // USDC on Arbitrum
    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external {
        uint256 deployerPrivateKey;

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            uint32 index = uint32(vm.envOr("DERIVATION_INDEX", uint256(0)));
            deployerPrivateKey = vm.deriveKey(mnemonic, index);
        } else {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        }

        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));

        vm.startBroadcast(deployerPrivateKey);

        CCTPBridgeAdapter adapter = new CCTPBridgeAdapter{salt: salt}(
            TOKEN_MESSENGER_V2,
            USDC_ARBITRUM
        );
        console.log("CCTPBridgeAdapter deployed at:", address(adapter));

        vm.stopBroadcast();
    }
}
