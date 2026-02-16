// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Test, Vm } from "forge-std/Test.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { ILiquidityController } from "interfaces/L2/ILiquidityController.sol";
import { L1CGTBridge } from "src/L1CGTBridge.sol";
import { L2CGTBridge } from "src/L2CGTBridge.sol";

contract L2CGTBridge_Test is Test {
    event DepositFinalized(address indexed from, address indexed to, uint256 l1Amount, uint256 l2Amount);
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 l2Amount, uint256 l1Amount);

    L2CGTBridge bridge;
    address messenger;
    address otherBridge;
    address liquidityController;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint8 constant TOKEN_DECIMALS = 6;
    uint256 constant SCALE_FACTOR = 10 ** 12; // 10 ** (18 - 6)

    function setUp() public {
        messenger = makeAddr("messenger");
        otherBridge = makeAddr("otherBridge");
        liquidityController = makeAddr("liquidityController");

        bridge = new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(messenger),
            TOKEN_DECIMALS,
            ILiquidityController(liquidityController)
        );
    }

    /// @notice Test that finalizeDeposit scales up and mints native asset.
    function test_finalizeDeposit_succeeds() external {
        uint256 l1Amount = 1_000_000; // 1 token (6 decimals)
        uint256 expectedL2Amount = l1Amount * SCALE_FACTOR;

        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(otherBridge)
        );
        vm.mockCall(
            liquidityController,
            abi.encodeCall(ILiquidityController.mint, (bob, expectedL2Amount)),
            ""
        );

        vm.expectCall(
            liquidityController,
            abi.encodeCall(ILiquidityController.mint, (bob, expectedL2Amount))
        );

        vm.expectEmit(true, true, true, true);
        emit DepositFinalized(alice, bob, l1Amount, expectedL2Amount);

        vm.prank(messenger);
        bridge.finalizeDeposit(alice, bob, l1Amount);
    }

    /// @notice Test that finalizeDeposit reverts when not called by the messenger.
    function test_finalizeDeposit_wrongSender_reverts() external {
        vm.prank(alice);
        vm.expectRevert("L2CGTBridge: caller is not the messenger");
        bridge.finalizeDeposit(alice, bob, 1_000_000);
    }

    /// @notice Test that finalizeDeposit reverts when xDomainMessageSender is wrong.
    function test_finalizeDeposit_wrongXDomainSender_reverts() external {
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(alice) // wrong sender
        );

        vm.prank(messenger);
        vm.expectRevert("L2CGTBridge: message not from other bridge");
        bridge.finalizeDeposit(alice, bob, 1_000_000);
    }

    /// @notice Fuzz test that decimal scaling is always correct.
    function test_finalizeDeposit_scalingCorrect(uint128 _l1Amount) external {
        vm.assume(_l1Amount > 0);
        uint256 l1Amount = uint256(_l1Amount);
        uint256 expectedL2Amount = l1Amount * SCALE_FACTOR;

        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(otherBridge)
        );
        vm.mockCall(
            liquidityController,
            abi.encodeWithSelector(ILiquidityController.mint.selector),
            ""
        );

        vm.prank(messenger);
        bridge.finalizeDeposit(alice, bob, l1Amount);

        // Verify the scaling is reversible: l2Amount / SCALE_FACTOR == l1Amount
        assertEq(expectedL2Amount / SCALE_FACTOR, l1Amount);
    }

    /// @notice Test that withdraw scales down, burns, and sends a message.
    function test_withdraw_succeeds() external {
        uint256 l2Amount = 1 ether; // 1 native token
        uint256 expectedL1Amount = l2Amount / SCALE_FACTOR; // 1_000_000

        // Give alice ETH and mock external calls
        vm.deal(alice, l2Amount);
        vm.mockCall(liquidityController, abi.encodeWithSelector(ILiquidityController.burn.selector), "");
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        // Expect the correct sendMessage call
        bytes memory expectedMessage =
            abi.encodeCall(L1CGTBridge.finalizeWithdrawal, (bob, expectedL1Amount));
        vm.expectCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (otherBridge, expectedMessage, 100_000))
        );

        vm.recordLogs();

        vm.prank(alice);
        bridge.withdraw{ value: l2Amount }(bob, 100_000);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("WithdrawalInitiated(address,address,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        (uint256 logL2Amount, uint256 logL1Amount) = abi.decode(logs[0].data, (uint256, uint256));
        assertEq(logL2Amount, l2Amount);
        assertEq(logL1Amount, expectedL1Amount);
    }

    /// @notice Test that withdraw reverts if value is not cleanly divisible.
    function test_withdraw_notDivisible_reverts() external {
        uint256 l2Amount = 1 ether + 1; // has dust

        vm.deal(alice, l2Amount);
        vm.prank(alice);
        vm.expectRevert("L2CGTBridge: value not cleanly divisible by scale factor");
        bridge.withdraw{ value: l2Amount }(bob, 100_000);
    }

    /// @notice Test that withdraw reverts if value is zero.
    function test_withdraw_zeroValue_reverts() external {
        vm.prank(alice);
        vm.expectRevert("L2CGTBridge: must send nonzero value");
        bridge.withdraw{ value: 0 }(bob, 100_000);
    }

    /// @notice Test that the constructor reverts if decimals >= 18.
    function test_constructor_invalidDecimals_reverts() external {
        vm.expectRevert("L2CGTBridge: token must have fewer than 18 decimals");
        new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(messenger),
            18,
            ILiquidityController(liquidityController)
        );
    }

    /// @notice Test the scale factor is computed correctly for various decimal counts.
    function test_scaleFactorCorrect() external {
        // 6 decimals: scale factor should be 10^12
        assertEq(bridge.DECIMAL_SCALE_FACTOR(), 10 ** 12);

        // 8 decimals: scale factor should be 10^10
        L2CGTBridge bridge8 = new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(messenger),
            8,
            ILiquidityController(liquidityController)
        );
        assertEq(bridge8.DECIMAL_SCALE_FACTOR(), 10 ** 10);

        // 2 decimals: scale factor should be 10^16
        L2CGTBridge bridge2 = new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(messenger),
            2,
            ILiquidityController(liquidityController)
        );
        assertEq(bridge2.DECIMAL_SCALE_FACTOR(), 10 ** 16);
    }

    /// @notice Test that the constructor reverts if other bridge is zero address.
    function test_constructor_zeroOtherBridge_reverts() external {
        vm.expectRevert("L2CGTBridge: other bridge is zero address");
        new L2CGTBridge(
            address(0),
            ICrossDomainMessenger(messenger),
            TOKEN_DECIMALS,
            ILiquidityController(liquidityController)
        );
    }

    /// @notice Test that the constructor reverts if messenger is zero address.
    function test_constructor_zeroMessenger_reverts() external {
        vm.expectRevert("L2CGTBridge: messenger is zero address");
        new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(address(0)),
            TOKEN_DECIMALS,
            ILiquidityController(liquidityController)
        );
    }

    /// @notice Test that the constructor reverts if liquidity controller is zero address.
    function test_constructor_zeroLiquidityController_reverts() external {
        vm.expectRevert("L2CGTBridge: liquidity controller is zero address");
        new L2CGTBridge(
            otherBridge,
            ICrossDomainMessenger(messenger),
            TOKEN_DECIMALS,
            ILiquidityController(address(0))
        );
    }

    /// @notice Test that withdraw reverts when withdrawing to zero address.
    function test_withdraw_zeroAddress_reverts() external {
        uint256 l2Amount = 1 ether;
        vm.deal(alice, l2Amount);
        vm.prank(alice);
        vm.expectRevert("L2CGTBridge: cannot withdraw to zero address");
        bridge.withdraw{ value: l2Amount }(address(0), 100_000);
    }

    /// @notice Roundtrip test: deposit X on L1, get X*scale on L2, withdraw back, get X on L1.
    function test_depositAndWithdraw_roundtrip() external {
        uint256 l1Amount = 5_000_000; // 5 tokens (6 decimals)
        uint256 l2Amount = l1Amount * SCALE_FACTOR;

        // Simulate finalize deposit
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(otherBridge)
        );
        vm.mockCall(
            liquidityController,
            abi.encodeWithSelector(ILiquidityController.mint.selector),
            ""
        );

        vm.prank(messenger);
        bridge.finalizeDeposit(alice, alice, l1Amount);

        // Simulate withdrawal
        vm.mockCall(liquidityController, abi.encodeWithSelector(ILiquidityController.burn.selector), "");
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        // Verify the withdrawal message contains the original l1Amount
        bytes memory expectedMessage =
            abi.encodeCall(L1CGTBridge.finalizeWithdrawal, (alice, l1Amount));
        vm.expectCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (otherBridge, expectedMessage, 100_000))
        );

        vm.deal(alice, l2Amount);
        vm.prank(alice);
        bridge.withdraw{ value: l2Amount }(alice, 100_000);

        // The l1Amount recovered is the same as what was deposited
        assertEq(l2Amount / SCALE_FACTOR, l1Amount);
    }
}
