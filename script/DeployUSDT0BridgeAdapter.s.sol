// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {USDT0BridgeAdapter} from "../src/USDT0BridgeAdapter.sol";

contract DeployUSDT0BridgeAdapter is Script {
    // USDT0 token on Arbitrum (ERC20)
    address constant USDT0_TOKEN_ARBITRUM = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    // USDT0 OFTAdapter on Arbitrum (has quoteSend/send)
    // See: https://docs.usdt0.to/technical-documentation/deployments
    address constant USDT0_OFT_ARBITRUM = 0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92;

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

        address deployer = vm.addr(deployerPrivateKey);
        USDT0BridgeAdapter adapter = new USDT0BridgeAdapter{salt: salt}(USDT0_TOKEN_ARBITRUM, USDT0_OFT_ARBITRUM, deployer);
        console.log("USDT0BridgeAdapter deployed at:", address(adapter));
        console.log("Owner:", adapter.owner());

        vm.stopBroadcast();
    }
}
