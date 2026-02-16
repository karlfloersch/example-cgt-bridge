// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { ILiquidityController } from "interfaces/L2/ILiquidityController.sol";
import { ISemver } from "interfaces/universal/ISemver.sol";
import { L1CGTBridge } from "src/L1CGTBridge.sol";

/// @title L2CGTBridge
/// @notice Example L2 bridge contract for Custom Gas Token (CGT) deposits and withdrawals.
///         Acts as an authorized minter on the LiquidityController. Receives cross-chain
///         deposit messages from L1CGTBridge, scales decimals up, and mints native asset.
///         On withdrawal, scales decimals down, burns native asset, and sends a message to L1.
///         Each deployment is paired with a single L1CGTBridge for one specific token.
///         This is an illustrative contract — not a production protocol contract.
contract L2CGTBridge is ISemver {
    /// @notice Semantic version.
    /// @custom:semver 0.1.0
    string public constant version = "0.1.0";

    /// @notice The paired L1CGTBridge contract address.
    address public immutable OTHER_BRIDGE;

    /// @notice The L2 cross-domain messenger used for sending/receiving cross-chain messages.
    ICrossDomainMessenger public immutable MESSENGER;

    /// @notice The decimal count of the L1 token.
    uint8 public immutable TOKEN_DECIMALS;

    /// @notice The LiquidityController predeploy used for minting and burning native asset.
    ILiquidityController public immutable LIQUIDITY_CONTROLLER;

    /// @notice The factor used to scale between L1 token decimals and 18 decimals.
    ///         Equal to 10 ** (18 - TOKEN_DECIMALS).
    uint256 public immutable DECIMAL_SCALE_FACTOR;

    /// @notice Emitted when a deposit from L1 is finalized and native asset is minted on L2.
    /// @param from     The depositor's address on L1.
    /// @param to       The recipient address on L2.
    /// @param l1Amount The amount in L1 token decimals.
    /// @param l2Amount The amount in 18 decimals (native asset).
    event DepositFinalized(address indexed from, address indexed to, uint256 l1Amount, uint256 l2Amount);

    /// @notice Emitted when a user initiates a withdrawal from L2 to L1.
    /// @param from     The address initiating the withdrawal on L2.
    /// @param to       The recipient address on L1.
    /// @param l2Amount The amount of native asset burned (18 decimals).
    /// @param l1Amount The amount to be received on L1 (L1 token decimals).
    event WithdrawalInitiated(address indexed from, address indexed to, uint256 l2Amount, uint256 l1Amount);

    /// @param _otherBridge         Address of the paired L1CGTBridge.
    /// @param _messenger           Address of the L2 cross-domain messenger.
    /// @param _tokenDecimals       Decimal count of the L1 token.
    /// @param _liquidityController Address of the LiquidityController predeploy.
    constructor(
        address _otherBridge,
        ICrossDomainMessenger _messenger,
        uint8 _tokenDecimals,
        ILiquidityController _liquidityController
    ) {
        require(_otherBridge != address(0), "L2CGTBridge: other bridge is zero address");
        require(address(_messenger) != address(0), "L2CGTBridge: messenger is zero address");
        require(address(_liquidityController) != address(0), "L2CGTBridge: liquidity controller is zero address");
        require(_tokenDecimals < 18, "L2CGTBridge: token must have fewer than 18 decimals");
        OTHER_BRIDGE = _otherBridge;
        MESSENGER = _messenger;
        TOKEN_DECIMALS = _tokenDecimals;
        LIQUIDITY_CONTROLLER = _liquidityController;
        DECIMAL_SCALE_FACTOR = 10 ** (18 - _tokenDecimals);
    }

    /// @notice Finalizes a deposit from L1 by scaling the amount up and minting native asset.
    ///         Can only be called by the messenger relaying a message from the paired L1CGTBridge.
    /// @param _from     The depositor's address on L1.
    /// @param _to       The recipient address on L2.
    /// @param _l1Amount The amount in L1 token decimals.
    function finalizeDeposit(address _from, address _to, uint256 _l1Amount) external {
        require(msg.sender == address(MESSENGER), "L2CGTBridge: caller is not the messenger");
        require(
            MESSENGER.xDomainMessageSender() == OTHER_BRIDGE,
            "L2CGTBridge: message not from other bridge"
        );

        uint256 l2Amount = _l1Amount * DECIMAL_SCALE_FACTOR;
        LIQUIDITY_CONTROLLER.mint(_to, l2Amount);

        emit DepositFinalized(_from, _to, _l1Amount, l2Amount);
    }

    /// @notice Withdraws native asset from L2 to L1 by burning it and sending a cross-chain
    ///         message to release L1 tokens. The sent value must be cleanly divisible by the
    ///         scale factor — no silent rounding occurs.
    /// @param _to          The recipient address on L1.
    /// @param _minGasLimit Minimum gas limit for the cross-chain message.
    function withdraw(address _to, uint32 _minGasLimit) external payable {
        require(_to != address(0), "L2CGTBridge: cannot withdraw to zero address");
        require(msg.value > 0, "L2CGTBridge: must send nonzero value");
        require(msg.value % DECIMAL_SCALE_FACTOR == 0, "L2CGTBridge: value not cleanly divisible by scale factor");

        uint256 l1Amount = msg.value / DECIMAL_SCALE_FACTOR;
        LIQUIDITY_CONTROLLER.burn{ value: msg.value }();

        bytes memory message = abi.encodeCall(L1CGTBridge.finalizeWithdrawal, (_to, l1Amount));
        MESSENGER.sendMessage(OTHER_BRIDGE, message, _minGasLimit);

        emit WithdrawalInitiated(msg.sender, _to, msg.value, l1Amount);
    }
}
