// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AtomicSwapHTLC.sol";
import "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

contract DeployHTLC is Script {
    function run() external {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address swapRouter = vm.envAddress("UNISWAP_V3_ROUTER");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy ERC2771Forwarder for meta-transactions
        console.log("Deploying ERC2771Forwarder...");
        ERC2771Forwarder forwarder = new ERC2771Forwarder("LendaswapForwarder");
        console.log("ERC2771Forwarder deployed at:", address(forwarder));

        // Deploy AtomicSwapHTLC
        console.log("Deploying AtomicSwapHTLC...");
        AtomicSwapHTLC htlc = new AtomicSwapHTLC(swapRouter, address(forwarder));
        console.log("AtomicSwapHTLC deployed at:", address(htlc));

        vm.stopBroadcast();

        // Log deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Network: Polygon");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Uniswap V3 Router:", swapRouter);
        console.log("ERC2771Forwarder:", address(forwarder));
        console.log("AtomicSwapHTLC:", address(htlc));
        console.log("========================\n");

        // Save deployment addresses
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "forwarder": "',
            vm.toString(address(forwarder)),
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
