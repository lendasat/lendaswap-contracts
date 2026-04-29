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

    // Bare 32-byte "cctp-forward" magic — Circle's standard forwarding hookData.
    bytes constant FORWARD_HOOK_32 =
        hex"636374702d666f72776172640000000000000000000000000000000000000000";

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
        assertEq(keccak256(bytes(adapter.VERSION())), keccak256(bytes("3")));
    }

    // -- bridgeBalance() tests --

    function test_bridgeBalance_success() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        adapter.bridgeBalance(0, recipient, 200_000, FORWARD_HOOK_32);
        vm.stopPrank();

        assertEq(tokenMessenger.lastAmount(), 100_000e6);
        assertEq(tokenMessenger.lastMintRecipient(), recipient);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_bridgeBalance_accepts_solana_extended_hookdata() public {
        // Solana ATA-creation forward payload: 28-byte cctp-forward prefix +
        // 4-byte length (0x21) + 1-byte ATA flag + 32-byte wallet pubkey = 65.
        bytes memory solanaHook = bytes.concat(
            hex"636374702d666f727761726400000000000000000000000000000000",
            hex"00000021",
            hex"01",
            hex"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        );
        assertEq(solanaHook.length, 65);

        // mintRecipient for Solana is the user's USDC ATA, not their wallet pubkey.
        bytes32 ata = bytes32(uint256(0xdeadbeef));

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.bridgeBalance(5, ata, 250_000, solanaHook);
        vm.stopPrank();

        assertEq(tokenMessenger.lastDestinationDomain(), 5);
        assertEq(tokenMessenger.lastMintRecipient(), ata);
    }

    function test_bridgeBalance_emits_event() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit CCTPBridgeAdapter.BridgeInitiated(3, recipient, 100_000e6, alice);

        adapter.bridgeBalance(3, recipient, 200_000, FORWARD_HOOK_32);
        vm.stopPrank();
    }

    function test_bridgeBalance_reverts_zero_recipient() public {
        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(CCTPBridgeAdapter.ZeroRecipient.selector);
        adapter.bridgeBalance(0, bytes32(0), 200_000, FORWARD_HOOK_32);
        vm.stopPrank();
    }

    function test_bridgeBalance_reverts_zero_balance() public {
        address broke = makeAddr("broke");
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(broke);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(CCTPBridgeAdapter.ZeroAmount.selector);
        adapter.bridgeBalance(0, recipient, 200_000, FORWARD_HOOK_32);
        vm.stopPrank();
    }

    function test_bridgeBalance_reverts_invalid_hookdata_length() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.startPrank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        // 31 bytes — neither the bare 32-byte magic nor the 65-byte Solana payload.
        bytes memory bad = hex"636374702d666f72776172640000000000000000000000000000000000000000ff";
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPBridgeAdapter.InvalidHookDataLength.selector,
                bad.length
            )
        );
        adapter.bridgeBalance(0, recipient, 200_000, bad);
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
