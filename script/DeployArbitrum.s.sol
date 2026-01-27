// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AtomicSwapHTLC} from "../src/AtomicSwapHTLC.sol";
import {ReverseAtomicSwapHTLC} from "../src/ReverseAtomicSwapHTLC.sol";
import {ERC20HTLC} from "../src/ERC20HTLC.sol";

contract DeployArbitrum is Script {
    // Arbitrum Uniswap V3 SwapRouter
    address constant ARBITRUM_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // Gelato's ERC2771 forwarder on Arbitrum
    address constant ARBITRUM_FORWARDER = 0xd8253782c45a12053594b9deB72d8e8aB2Fca54c;

    function run() external {
        // Support both PRIVATE_KEY and MNEMONIC
        // If MNEMONIC is set, derive the key; otherwise use PRIVATE_KEY directly
        uint256 deployerPrivateKey;

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            uint32 index = uint32(vm.envOr("DERIVATION_INDEX", uint256(0)));
            deployerPrivateKey = vm.deriveKey(mnemonic, index);
        } else {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AtomicSwapHTLC
        AtomicSwapHTLC htlc = new AtomicSwapHTLC(ARBITRUM_SWAP_ROUTER, ARBITRUM_FORWARDER);
        console.log("AtomicSwapHTLC deployed at:", address(htlc));

        // Deploy ReverseAtomicSwapHTLC
        ReverseAtomicSwapHTLC reverseHtlc = new ReverseAtomicSwapHTLC(ARBITRUM_SWAP_ROUTER, ARBITRUM_FORWARDER);
        console.log("ReverseAtomicSwapHTLC deployed at:", address(reverseHtlc));

        // Deploy ERC20HTLC
        ERC20HTLC erc20Htlc = new ERC20HTLC(ARBITRUM_FORWARDER);
        console.log("ERC20HTLC deployed at:", address(erc20Htlc));

        vm.stopBroadcast();
    }
}
