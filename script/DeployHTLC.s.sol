// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AtomicSwapHTLC.sol";

contract DeployHTLC is Script {
    // Gelato's GelatoRelay1BalanceERC2771 forwarder on Polygon mainnet
    // This enables gasless transactions via Gelato's 1Balance system
    address constant GELATO_FORWARDER = 0xd8253782c45a12053594b9deB72d8e8aB2Fca54c;

    function run() external {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address swapRouter = vm.envAddress("UNISWAP_V3_ROUTER");

        // Allow override of forwarder address via environment variable
        address forwarder = vm.envOr("FORWARDER_ADDRESS", GELATO_FORWARDER);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AtomicSwapHTLC with Gelato's forwarder
        console.log("Deploying AtomicSwapHTLC...");
        console.log("Using ERC2771Forwarder at:", forwarder);
        AtomicSwapHTLC htlc = new AtomicSwapHTLC(swapRouter, forwarder);
        console.log("AtomicSwapHTLC deployed at:", address(htlc));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Network: Polygon");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Uniswap V3 Router:", swapRouter);
        console.log("ERC2771Forwarder (Gelato):", forwarder);
        console.log("AtomicSwapHTLC:", address(htlc));
        console.log("========================\n");

        // Save deployment addresses
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "forwarder": "',
            vm.toString(forwarder),
            '",\n',
            '  "htlc": "',
            vm.toString(address(htlc)),
            '",\n',
            '  "router": "',
            vm.toString(swapRouter),
            '"\n',
            "}"
        );

        vm.writeFile("deployments.json", deploymentInfo);
        console.log("Deployment info saved to deployments.json");
    }
}

