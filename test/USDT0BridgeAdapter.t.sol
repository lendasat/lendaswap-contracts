// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USDT0BridgeAdapter} from "../src/USDT0BridgeAdapter.sol";
import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "../src/interfaces/IOFT.sol";

// -- Mock contracts --

contract MockUSDT0 is ERC20 {
    constructor() ERC20("USDT0", "USDT0") {
        _mint(msg.sender, 10_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockOFT is IOFT {
    IERC20 public immutable usdt0Token;

    uint256 public lastAmountLD;
    uint32 public lastDstEid;
    bytes32 public lastTo;
    uint256 public lastNativeFee;

    /// Configurable fee returned by quoteSend
    uint256 public mockNativeFee = 50_000_000_000_000; // 0.00005 ETH

    constructor(address _usdt0Token) {
        usdt0Token = IERC20(_usdt0Token);
    }

    function setMockNativeFee(uint256 fee) external {
        mockNativeFee = fee;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: mockNativeFee, lzTokenFee: 0});
    }

    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        // Simulate OFTAdapter behavior: pull tokens from msg.sender
        usdt0Token.transferFrom(msg.sender, address(this), _sendParam.amountLD);

        lastAmountLD = _sendParam.amountLD;
        lastDstEid = _sendParam.dstEid;
        lastTo = _sendParam.to;
        lastNativeFee = _fee.nativeFee;

        // Simulate LZ refund: return excess ETH to refund address
        uint256 refund = msg.value - _fee.nativeFee;
        if (refund > 0) {
            (bool success,) = _refundAddress.call{value: refund}("");
            require(success, "MockOFT: refund failed");
        }

        return (
            MessagingReceipt({guid: bytes32(0), nonce: 1, fee: _fee}),
            OFTReceipt({amountSentLD: _sendParam.amountLD, amountReceivedLD: _sendParam.amountLD})
        );
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function token() external view returns (address) {
        return address(usdt0Token);
    }
}

/// @dev Helper to receive ETH refunds (EOAs can't in forge tests without this)
contract TestCaller {
    USDT0BridgeAdapter public adapter;
    IERC20 public usdt0;

    constructor(USDT0BridgeAdapter _adapter, IERC20 _usdt0) {
        adapter = _adapter;
        usdt0 = _usdt0;
    }

    function callBridge(uint32 dstEid, bytes32 to) external payable {
        usdt0.approve(address(adapter), type(uint256).max);
        adapter.bridgeBalance{value: msg.value}(dstEid, to);
    }

    receive() external payable {}
}

// -- Tests --

contract USDT0BridgeAdapterTest is Test {
    MockUSDT0 usdt0;
    MockOFT oft;
    USDT0BridgeAdapter adapter;
    TestCaller caller;

    address bob = makeAddr("bob");

    uint32 constant DST_EID_OPTIMISM = 30111;

    function setUp() public {
        usdt0 = new MockUSDT0();
        oft = new MockOFT(address(usdt0));
        adapter = new USDT0BridgeAdapter(address(usdt0), address(oft), address(this));
        caller = new TestCaller(adapter, IERC20(address(usdt0)));

        // Fund caller contract with USDT0 and ETH
        usdt0.transfer(address(caller), 100_000e6);
        vm.deal(address(caller), 1 ether);
    }

    // -- version --

    function test_version() public view {
        assertEq(keccak256(bytes(adapter.VERSION())), keccak256(bytes("5")));
    }

    // -- bridgeBalance() success --

    function test_bridgeBalance_success() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        caller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, recipient);

        // OFT received the tokens
        assertEq(oft.lastAmountLD(), 100_000e6);
        assertEq(oft.lastDstEid(), DST_EID_OPTIMISM);
        assertEq(oft.lastTo(), recipient);
        // Caller's token balance is 0
        assertEq(usdt0.balanceOf(address(caller)), 0);
        // OFT received exactly the quoteSend fee, not the full msg.value
        assertEq(oft.lastNativeFee(), oft.mockNativeFee());
    }

    function test_bridgeBalance_pulls_full_balance() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        // Give caller a different amount
        deal(address(usdt0), address(caller), 42e6);

        caller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, recipient);

        assertEq(oft.lastAmountLD(), 42e6);
        assertEq(usdt0.balanceOf(address(caller)), 0);
    }

    // -- bridgeBalance() refunds excess ETH --

    function test_bridgeBalance_excess_eth_accumulates_in_adapter() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        assertEq(address(adapter).balance, 0);

        caller.callBridge{value: 0.1 ether}(DST_EID_OPTIMISM, recipient);

        // Excess ETH accumulates in adapter (LZ refunds to adapter, not coordinator)
        // This prevents ETH from being trapped in the coordinator which can't sweep ETH.
        uint256 excess = 0.1 ether - oft.mockNativeFee();
        assertEq(address(adapter).balance, excess);
    }

    // -- bridgeBalance() emits event --

    function test_bridgeBalance_emits_event() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.expectEmit(true, true, false, true);
        emit USDT0BridgeAdapter.BridgeInitiated(
            DST_EID_OPTIMISM, recipient, 100_000e6, oft.mockNativeFee(), address(caller)
        );

        caller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, recipient);
    }

    // -- bridgeBalance() reverts --

    function test_bridgeBalance_reverts_zero_recipient() public {
        vm.expectRevert(USDT0BridgeAdapter.ZeroRecipient.selector);
        caller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, bytes32(0));
    }

    function test_bridgeBalance_reverts_zero_balance() public {
        // Deploy a fresh caller with no USDT0
        TestCaller brokeCaller = new TestCaller(adapter, IERC20(address(usdt0)));
        vm.deal(address(brokeCaller), 1 ether);
        bytes32 recipient = adapter.addressToBytes32(bob);

        vm.expectRevert(USDT0BridgeAdapter.ZeroAmount.selector);
        brokeCaller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, recipient);
    }

    function test_bridgeBalance_reverts_insufficient_fee() public {
        bytes32 recipient = adapter.addressToBytes32(bob);

        // Set a high mock fee
        oft.setMockNativeFee(1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                USDT0BridgeAdapter.InsufficientEthForFee.selector, 1 ether, 0.001 ether
            )
        );
        caller.callBridge{value: 0.001 ether}(DST_EID_OPTIMISM, recipient);
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
        address original = address(caller);
        bytes32 asBytes = adapter.addressToBytes32(original);
        address recovered = adapter.bytes32ToAddress(asBytes);
        assertEq(recovered, original);
    }

    // -- Immutables --

    function test_immutables() public view {
        assertEq(address(adapter.USDT0_TOKEN()), address(usdt0));
        assertEq(address(adapter.USDT0_OFT()), address(oft));
    }
}
