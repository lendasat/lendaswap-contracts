// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HTLCErc20} from "../src/HTLCErc20.sol";

/// @notice The EIP-712 domain's version string tracks `VERSION`. Signers hardcode this
///         value off-chain, so a drift between the two silently breaks every
///         `redeemBySig` / `refundBySig` signature rather than failing loudly at deploy.
contract HTLCErc20DomainTest is Test {
    HTLCErc20 htlc;

    function setUp() public {
        htlc = new HTLCErc20();
    }

    function test_domainVersionTracksContractVersion() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HTLCErc20"),
                keccak256(bytes(vm.toString(uint256(htlc.VERSION())))),
                block.chainid,
                address(htlc)
            )
        );

        assertEq(htlc.DOMAIN_SEPARATOR(), expected, "domain version must equal VERSION");
    }
}
