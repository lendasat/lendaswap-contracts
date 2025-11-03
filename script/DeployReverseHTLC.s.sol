// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ReverseAtomicSwapHTLC.sol";

contract DeployReverseHTLC is Script {
    // Polygon mainnet addresses
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant GELATO_FORWARDER = 0xd8253782c45a12053594b9deB72d8e8aB2Fca54c;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying ReverseAtomicSwapHTLC...");
        console.log("Uniswap V3 Router:", UNISWAP_V3_ROUTER);
        console.log("Gelato Forwarder:", GELATO_FORWARDER);

        ReverseAtomicSwapHTLC htlc = new ReverseAtomicSwapHTLC(
            UNISWAP_V3_ROUTER,
            GELATO_FORWARDER
        );

        console.log("ReverseAtomicSwapHTLC deployed at:", address(htlc));

        vm.stopBroadcast();
    }
}
