// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CCTPBridgeAdapter} from "../src/CCTPBridgeAdapter.sol";
import {ITokenMessenger} from "../src/interfaces/ITokenMessenger.sol";
import {IMessageTransmitter} from "../src/interfaces/IMessageTransmitter.sol";

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

        // Simulate burn by transferring USDC from caller to this contract
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

contract MockMessageTransmitter is IMessageTransmitter {
    address public usdc;
    uint256 public mintAmount;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    /// @dev Set how much USDC to mint on the next receiveMessage call
    function setMintAmount(uint256 amount) external {
        mintAmount = amount;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        // Simulate minting USDC to msg.sender (the adapter)
        MockUSDC(usdc).transfer(msg.sender, mintAmount);
        return true;
    }

    function localDomain() external pure returns (uint32) {
        return 7; // Polygon
    }
}

// -- Tests --

contract CCTPBridgeAdapterTest is Test {
    MockUSDC usdc;
    MockTokenMessenger tokenMessenger;
    MockMessageTransmitter messageTransmitter;
    CCTPBridgeAdapter adapter;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        tokenMessenger = new MockTokenMessenger(address(usdc));
        messageTransmitter = new MockMessageTransmitter(address(usdc));

        adapter = new CCTPBridgeAdapter(
            address(tokenMessenger),
            address(messageTransmitter),
            address(usdc)
        );

        // Fund alice with USDC
        usdc.transfer(alice, 100_000e6);

        // Fund messageTransmitter with USDC (simulates minting capability)
        usdc.transfer(address(messageTransmitter), 1_000_000e6);
    }

    // -- bridge() tests --

    function test_bridge_success() public {
        uint256 amount = 1000e6;
        uint32 destDomain = 0; // Ethereum
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), amount);
        uint64 nonce = adapter.bridge(amount, destDomain, recipient);
        vm.stopPrank();

        assertEq(nonce, 1);
        assertEq(tokenMessenger.lastAmount(), amount);
        assertEq(tokenMessenger.lastDestinationDomain(), destDomain);
        assertEq(tokenMessenger.lastMintRecipient(), recipient);
        assertEq(usdc.balanceOf(alice), 100_000e6 - amount);
    }

    function test_bridge_emits_event() public {
        uint256 amount = 500e6;
        uint32 destDomain = 3; // Arbitrum
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), amount);

        vm.expectEmit(true, true, true, true);
        emit CCTPBridgeAdapter.BridgeInitiated(1, destDomain, recipient, amount, alice);

        adapter.bridge(amount, destDomain, recipient);
        vm.stopPrank();
    }

    function test_bridge_reverts_zero_amount() public {
        bytes32 recipient = adapter.addressToBytes32(bob);
        vm.prank(alice);
        vm.expectRevert(CCTPBridgeAdapter.ZeroAmount.selector);
        adapter.bridge(0, 0, recipient);
    }

    function test_bridge_reverts_zero_recipient() public {
        vm.startPrank(alice);
        usdc.approve(address(adapter), 1000e6);

        vm.expectRevert(CCTPBridgeAdapter.ZeroRecipient.selector);
        adapter.bridge(1000e6, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_bridge_multiple_nonces() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), 2000e6);

        uint64 nonce1 = adapter.bridge(1000e6, 0, recipient);
        uint64 nonce2 = adapter.bridge(1000e6, 3, recipient);
        vm.stopPrank();

        assertEq(nonce1, 1);
        assertEq(nonce2, 2);
    }

    // -- bridgeWithCaller() tests --

    function test_bridgeWithCaller_success() public {
        uint256 amount = 1000e6;
        uint32 destDomain = 0;
        bytes32 recipient = adapter.addressToBytes32(bob);
        bytes32 destCaller = adapter.addressToBytes32(alice);

        vm.startPrank(alice);
        usdc.approve(address(adapter), amount);
        uint64 nonce = adapter.bridgeWithCaller(amount, destDomain, recipient, destCaller);
        vm.stopPrank();

        assertEq(nonce, 1);
        assertEq(tokenMessenger.lastDestinationCaller(), destCaller);
    }

    function test_bridgeWithCaller_reverts_zero_amount() public {
        bytes32 recipient = adapter.addressToBytes32(bob);
        vm.prank(alice);
        vm.expectRevert(CCTPBridgeAdapter.ZeroAmount.selector);
        adapter.bridgeWithCaller(0, 0, recipient, bytes32(0));
    }

    // -- receiveAndForward() tests --

    function test_receiveAndForward_success() public {
        uint256 amount = 5000e6;
        messageTransmitter.setMintAmount(amount);

        uint256 bobBefore = usdc.balanceOf(bob);

        adapter.receiveAndForward(
            hex"deadbeef", // mock message
            hex"cafebabe", // mock attestation
            bob,
            amount
        );

        assertEq(usdc.balanceOf(bob), bobBefore + amount);
    }

    function test_receiveAndForward_emits_event() public {
        uint256 amount = 2000e6;
        messageTransmitter.setMintAmount(amount);

        bytes memory message = hex"deadbeef";

        vm.expectEmit(true, false, false, true);
        emit CCTPBridgeAdapter.BridgeReceived(keccak256(message), bob, amount);

        adapter.receiveAndForward(message, hex"cafebabe", bob, amount);
    }

    function test_receiveAndForward_reverts_insufficient_mint() public {
        messageTransmitter.setMintAmount(999e6);

        vm.expectRevert("CCTPBridgeAdapter: insufficient mint");
        adapter.receiveAndForward(hex"deadbeef", hex"cafebabe", bob, 1000e6);
    }

    function test_receiveAndForward_extra_amount_forwarded() public {
        // Mint more than expected — all should be forwarded
        messageTransmitter.setMintAmount(1500e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        adapter.receiveAndForward(hex"aa", hex"bb", bob, 1000e6);

        assertEq(usdc.balanceOf(bob), bobBefore + 1500e6);
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

    // -- Domain constant tests --

    function test_domain_constants() public view {
        assertEq(adapter.DOMAIN_ETHEREUM(), 0);
        assertEq(adapter.DOMAIN_AVALANCHE(), 1);
        assertEq(adapter.DOMAIN_OPTIMISM(), 2);
        assertEq(adapter.DOMAIN_ARBITRUM(), 3);
        assertEq(adapter.DOMAIN_SOLANA(), 5);
        assertEq(adapter.DOMAIN_BASE(), 6);
        assertEq(adapter.DOMAIN_POLYGON(), 7);
    }
}
