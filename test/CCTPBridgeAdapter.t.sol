// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CCTPBridgeAdapter} from "../src/CCTPBridgeAdapter.sol";
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";

// -- Mock contracts --

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 10_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Simulate CCTP burn by just transferring to burn address
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockTokenMessenger is ITokenMessenger {
    uint64 public nextNonce = 1;
    address public usdc;

    // Track calls for assertions
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    bytes32 public lastDestinationCaller;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        require(burnToken == usdc, "MockTokenMessenger: wrong token");

        IERC20(usdc).transferFrom(msg.sender, address(this), amount);

        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastDestinationCaller = bytes32(0);

        nonce = nextNonce++;
    }

    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce) {
        require(burnToken == usdc, "MockTokenMessenger: wrong token");

        IERC20(usdc).transferFrom(msg.sender, address(this), amount);

        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastDestinationCaller = destinationCaller;

        nonce = nextNonce++;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256,
        uint32,
        bytes calldata
    ) external {
        require(burnToken == usdc, "MockTokenMessenger: wrong token");

        IERC20(usdc).transferFrom(msg.sender, address(this), amount);

        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastDestinationCaller = destinationCaller;

        nextNonce++;
    }

    function localMessageTransmitter() external pure returns (address) {
        return address(0);
    }

    function localMinter() external pure returns (address) {
        return address(0);
    }
}

// -- Tests --

contract CCTPBridgeAdapterTest is Test {
    MockUSDC usdc;
    MockTokenMessenger tokenMessenger;
    CCTPBridgeAdapter adapter;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        tokenMessenger = new MockTokenMessenger(address(usdc));

        adapter = new CCTPBridgeAdapter(
            address(tokenMessenger),
            address(usdc)
        );

        // Fund alice with USDC
        usdc.transfer(alice, 100_000e6);
    }

    // -- version --

    function test_version() public view {
        assertEq(keccak256(bytes(adapter.VERSION())), keccak256(bytes("2")));
    }

    // -- bridgeBalance() tests --

    function test_bridgeBalance_success() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        adapter.bridgeBalance(0, recipient, 200_000);
        vm.stopPrank();

        assertEq(tokenMessenger.lastAmount(), 100_000e6);
        assertEq(tokenMessenger.lastMintRecipient(), recipient);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_bridgeBalance_emits_event() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit CCTPBridgeAdapter.BridgeInitiated(3, recipient, 100_000e6, alice);

        adapter.bridgeBalance(3, recipient, 200_000);
        vm.stopPrank();
    }

    function test_bridgeBalance_reverts_zero_recipient() public {
        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(CCTPBridgeAdapter.ZeroRecipient.selector);
        adapter.bridgeBalance(0, bytes32(0), 200_000);
        vm.stopPrank();
    }

    function test_bridgeBalance_reverts_zero_balance() public {
        address broke = makeAddr("broke");
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(broke);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(CCTPBridgeAdapter.ZeroAmount.selector);
        adapter.bridgeBalance(0, recipient, 200_000);
        vm.stopPrank();
    }

    // -- View helper tests --

    function test_addressToBytes32() public view {
        address addr = 0x1234567890AbcdEF1234567890aBcdef12345678;
        bytes32 result = adapter.addressToBytes32(addr);
        assertEq(result, bytes32(uint256(uint160(addr))));
    }

    function test_bytes32ToAddress() public view {
        bytes32 b = bytes32(uint256(uint160(0x1234567890AbcdEF1234567890aBcdef12345678)));
        address result = adapter.bytes32ToAddress(b);
        assertEq(result, 0x1234567890AbcdEF1234567890aBcdef12345678);
    }

    function test_roundtrip_address_conversion() public view {
        address original = alice;
        bytes32 asBytes = adapter.addressToBytes32(original);
        address recovered = adapter.bytes32ToAddress(asBytes);
        assertEq(recovered, original);
    }
}
