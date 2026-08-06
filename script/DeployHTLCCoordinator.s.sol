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

        // CREATE2 salt for deterministic addresses across all chains.
        // Same salt + same bytecode + same deployer = same address everywhere.
        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));

        // Owner of the deployed HTLCErc20 — may only recover balances no swap is owed.
        // It is part of the init code, so the same value is needed on every chain for
        // the CREATE2 addresses to match. Defaults to the deployer.
        address htlcOwner = vm.envOr("HTLC_OWNER", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        HTLCErc20 htlc = new HTLCErc20{salt: salt}(htlcOwner);
        console.log("HTLCErc20 deployed at:", address(htlc));
        console.log("HTLCErc20 owner:", htlcOwner);

        // Canonical Permit2 address (deployed via CREATE2 on all chains)
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        HTLCCoordinator coordinator = new HTLCCoordinator{salt: salt}(address(htlc), permit2);
        console.log("HTLCCoordinator deployed at:", address(coordinator));

        vm.stopBroadcast();
    }
}
