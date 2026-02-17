// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { ISemver } from "interfaces/universal/ISemver.sol";
import { L2CGTBridge } from "src/L2CGTBridge.sol";

/// @title L1CGTBridge
/// @notice Example L1 bridge contract for Custom Gas Token (CGT) deposits and withdrawals.
///         Locks an L1 ERC-20 token on deposit and releases it on withdrawal finalization.
///         Each deployment is paired with a single L2CGTBridge instance for one specific token.
///         This is an illustrative contract — not a production protocol contract.
/// @dev    This bridge assumes a standard ERC-20 token. Fee-on-transfer and rebasing tokens
///         are NOT supported and will cause accounting mismatches.
contract L1CGTBridge is ISemver {
    using SafeERC20 for IERC20;

    /// @notice Semantic version.
    /// @custom:semver 0.1.0
    string public constant version = "0.1.0";

    /// @notice The L1 ERC-20 token that this bridge locks/releases.
    IERC20 public immutable L1_TOKEN;

    /// @notice The decimal count of the L1 token.
    uint8 public immutable TOKEN_DECIMALS;

    /// @notice The paired L2CGTBridge contract address.
    address public immutable OTHER_BRIDGE;

    /// @notice The L1 cross-domain messenger used for sending/receiving cross-chain messages.
    ICrossDomainMessenger public immutable MESSENGER;

    /// @notice Total amount of L1 tokens currently locked in this bridge.
    uint256 public totalDeposited;

    /// @notice Emitted when a user deposits L1 tokens to be bridged to L2.
    /// @param from    The address that initiated the deposit on L1.
    /// @param to      The recipient address on L2.
    /// @param amount  The amount of L1 tokens deposited (in L1 token decimals).
    event Deposit(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when a withdrawal from L2 is finalized and L1 tokens are released.
    /// @param to      The recipient address on L1.
    /// @param amount  The amount of L1 tokens released (in L1 token decimals).
    event WithdrawalFinalized(address indexed to, uint256 amount);

    /// @param _l1Token      Address of the L1 ERC-20 token.
    /// @param _tokenDecimals Expected decimal count of the L1 token.
    /// @param _otherBridge   Address of the paired L2CGTBridge.
    /// @param _messenger     Address of the L1 cross-domain messenger.
    constructor(IERC20 _l1Token, uint8 _tokenDecimals, address _otherBridge, ICrossDomainMessenger _messenger) {
        require(address(_l1Token) != address(0), "L1CGTBridge: token is zero address");
        require(_otherBridge != address(0), "L1CGTBridge: other bridge is zero address");
        require(address(_messenger) != address(0), "L1CGTBridge: messenger is zero address");
        require(_tokenDecimals <= 18, "L1CGTBridge: token decimals must be <= 18");
        require(
            IERC20Metadata(address(_l1Token)).decimals() == _tokenDecimals,
            "L1CGTBridge: decimals mismatch"
        );
        L1_TOKEN = _l1Token;
        TOKEN_DECIMALS = _tokenDecimals;
        OTHER_BRIDGE = _otherBridge;
        MESSENGER = _messenger;
    }

    /// @notice Deposits L1 tokens into the bridge, locking them and sending a cross-chain
    ///         message to mint the equivalent native asset on L2.
    /// @param _to           The recipient address on L2.
    /// @param _amount       The amount of L1 tokens to deposit.
    /// @param _minGasLimit  Minimum gas limit for the cross-chain message.
    function deposit(address _to, uint256 _amount, uint32 _minGasLimit) external {
        require(_to != address(0), "L1CGTBridge: cannot deposit to zero address");
        require(_amount > 0, "L1CGTBridge: must deposit nonzero amount");
        L1_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
        totalDeposited += _amount;

        bytes memory message = abi.encodeCall(L2CGTBridge.finalizeDeposit, (msg.sender, _to, _amount));
        MESSENGER.sendMessage(OTHER_BRIDGE, message, _minGasLimit);

        emit Deposit(msg.sender, _to, _amount);
    }

    /// @notice Finalizes a withdrawal from L2 by releasing L1 tokens to the recipient.
    ///         Can only be called by the messenger relaying a message from the paired L2CGTBridge.
    /// @param _to     The recipient address on L1.
    /// @param _amount The amount of L1 tokens to release.
    function finalizeWithdrawal(address _to, uint256 _amount) external {
        require(msg.sender == address(MESSENGER), "L1CGTBridge: caller is not the messenger");
        require(
            MESSENGER.xDomainMessageSender() == OTHER_BRIDGE,
            "L1CGTBridge: message not from other bridge"
        );

        totalDeposited -= _amount;
        L1_TOKEN.safeTransfer(_to, _amount);

        emit WithdrawalFinalized(_to, _amount);
    }
}
