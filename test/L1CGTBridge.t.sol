// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { L1CGTBridge } from "src/L1CGTBridge.sol";
import { L2CGTBridge } from "src/L2CGTBridge.sol";

/// @notice A minimal ERC20 with configurable decimals for testing.
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract L1CGTBridge_Test is Test {
    event Deposit(address indexed from, address indexed to, uint256 amount);
    event WithdrawalFinalized(address indexed to, uint256 amount);

    L1CGTBridge bridge;
    MockERC20 token;
    address messenger;
    address otherBridge;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint8 constant TOKEN_DECIMALS = 6;

    function setUp() public {
        token = new MockERC20("Test Token", "TT", TOKEN_DECIMALS);
        messenger = makeAddr("messenger");
        otherBridge = makeAddr("otherBridge");

        bridge = new L1CGTBridge(
            IERC20(address(token)),
            TOKEN_DECIMALS,
            otherBridge,
            ICrossDomainMessenger(messenger)
        );
    }

    /// @notice Test that a deposit locks tokens and sends a cross-chain message.
    function test_deposit_succeeds() external {
        uint256 amount = 1_000_000; // 1 token (6 decimals)
        token.mint(alice, amount);

        vm.prank(alice);
        token.approve(address(bridge), amount);

        // Expect the messenger to be called with the correct message
        bytes memory expectedMessage =
            abi.encodeCall(L2CGTBridge.finalizeDeposit, (alice, bob, amount));
        vm.expectCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (otherBridge, expectedMessage, 100_000))
        );
        // Mock the sendMessage call so it doesn't revert
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        vm.expectEmit(true, true, true, true);
        emit Deposit(alice, bob, amount);

        vm.prank(alice);
        bridge.deposit(bob, amount, 100_000);

        assertEq(token.balanceOf(address(bridge)), amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(bridge.totalDeposited(), amount);
    }

    /// @notice Test that deposit reverts when the user has insufficient balance.
    function test_deposit_insufficientBalance_reverts() external {
        uint256 amount = 1_000_000;
        // alice has no tokens

        vm.prank(alice);
        token.approve(address(bridge), amount);

        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        vm.prank(alice);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bridge.deposit(bob, amount, 100_000);
    }

    /// @notice Test that finalizeWithdrawal releases tokens to the recipient.
    function test_finalizeWithdrawal_succeeds() external {
        // First deposit tokens so the bridge has a balance
        uint256 amount = 1_000_000;
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");
        vm.prank(alice);
        bridge.deposit(bob, amount, 100_000);

        // Now finalize a withdrawal
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(otherBridge)
        );

        vm.expectEmit(true, true, true, true);
        emit WithdrawalFinalized(bob, amount);

        vm.prank(messenger);
        bridge.finalizeWithdrawal(bob, amount);

        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(bridge)), 0);
        assertEq(bridge.totalDeposited(), 0);
    }

    /// @notice Test that finalizeWithdrawal reverts when not called by the messenger.
    function test_finalizeWithdrawal_wrongSender_reverts() external {
        vm.prank(alice);
        vm.expectRevert("L1CGTBridge: caller is not the messenger");
        bridge.finalizeWithdrawal(bob, 1_000_000);
    }

    /// @notice Test that finalizeWithdrawal reverts when xDomainMessageSender is not the other bridge.
    function test_finalizeWithdrawal_wrongXDomainSender_reverts() external {
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(alice) // wrong sender
        );

        vm.prank(messenger);
        vm.expectRevert("L1CGTBridge: message not from other bridge");
        bridge.finalizeWithdrawal(bob, 1_000_000);
    }

    /// @notice Test that the constructor reverts if decimals > 18.
    function test_constructor_invalidDecimals_reverts() external {
        MockERC20 token19 = new MockERC20("Token", "TKN", 19);
        vm.expectRevert("L1CGTBridge: token decimals must be <= 18");
        new L1CGTBridge(IERC20(address(token19)), 19, otherBridge, ICrossDomainMessenger(messenger));
    }

    /// @notice Test that the constructor reverts if decimals don't match the token.
    function test_constructor_decimalsMismatch_reverts() external {
        vm.expectRevert("L1CGTBridge: decimals mismatch");
        new L1CGTBridge(IERC20(address(token)), 8, otherBridge, ICrossDomainMessenger(messenger));
    }

    /// @notice Test that the constructor reverts if the token address is zero.
    function test_constructor_zeroToken_reverts() external {
        vm.expectRevert("L1CGTBridge: token is zero address");
        new L1CGTBridge(IERC20(address(0)), TOKEN_DECIMALS, otherBridge, ICrossDomainMessenger(messenger));
    }

    /// @notice Test that the constructor reverts if the other bridge address is zero.
    function test_constructor_zeroOtherBridge_reverts() external {
        vm.expectRevert("L1CGTBridge: other bridge is zero address");
        new L1CGTBridge(IERC20(address(token)), TOKEN_DECIMALS, address(0), ICrossDomainMessenger(messenger));
    }

    /// @notice Test that the constructor reverts if the messenger address is zero.
    function test_constructor_zeroMessenger_reverts() external {
        vm.expectRevert("L1CGTBridge: messenger is zero address");
        new L1CGTBridge(IERC20(address(token)), TOKEN_DECIMALS, otherBridge, ICrossDomainMessenger(address(0)));
    }

    /// @notice Test that deposit reverts when depositing to the zero address.
    function test_deposit_zeroAddress_reverts() external {
        uint256 amount = 1_000_000;
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(bridge), amount);
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        vm.prank(alice);
        vm.expectRevert("L1CGTBridge: cannot deposit to zero address");
        bridge.deposit(address(0), amount, 100_000);
    }

    /// @notice Test that deposit reverts when depositing zero amount.
    function test_deposit_zeroAmount_reverts() external {
        vm.mockCall(messenger, abi.encodeWithSelector(ICrossDomainMessenger.sendMessage.selector), "");

        vm.prank(alice);
        vm.expectRevert("L1CGTBridge: must deposit nonzero amount");
        bridge.deposit(bob, 0, 100_000);
    }
}
