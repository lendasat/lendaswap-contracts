// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HTLCErc20, SwapKey} from "../src/HTLCErc20.sol";

/// @notice `_key` is hand-rolled assembly, but the layout it hashes is exactly
///         `abi.encode` of the six parameters. Off-chain consumers rebuild the key from
///         that encoding, so this pins the two together.
contract HTLCErc20KeyTest is Test {
    HTLCErc20 htlc;

    function setUp() public {
        htlc = new HTLCErc20(address(this));
    }

    function testFuzz_keyIsAbiEncodedParameters(
        bytes32 preimageHash,
        uint256 amount,
        address token,
        address sender,
        address claimAddress,
        uint256 timelock
    ) public view {
        assertEq(
            SwapKey.unwrap(htlc.computeKey(preimageHash, amount, token, sender, claimAddress, timelock)),
            keccak256(abi.encode(preimageHash, amount, token, sender, claimAddress, timelock)),
            "key must equal abi.encode of its parameters"
        );
    }

    /// The shared vector that off-chain key derivation is pinned to. If this value ever
    /// changes, every consumer that rebuilds keys has to change with it.
    function test_offChainVector() public view {
        assertEq(
            SwapKey.unwrap(
                htlc.computeKey(
                    bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111)),
                    100_000_000,
                    0x2222222222222222222222222222222222222222,
                    0x3333333333333333333333333333333333333333,
                    0x4444444444444444444444444444444444444444,
                    1_800_000_000
                )
            ),
            0x9bcefeea062c6f8939f1dac7aafe4ae66c40d816804fe22032bd3a242da7eeea,
            "vector"
        );
    }
}
