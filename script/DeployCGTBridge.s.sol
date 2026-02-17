// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { ILiquidityController } from "interfaces/L2/ILiquidityController.sol";
import { L1CGTBridge } from "src/L1CGTBridge.sol";
import { L2CGTBridge } from "src/L2CGTBridge.sol";

/// @title DeployCGTBridgeL1
/// @notice Deploys L1CGTBridge on L1. Part of the CGT decimal bridge deployment workflow.
///
/// @dev Full deployment workflow:
///
///      1. Predict the L2CGTBridge address from the deployer address and L2 nonce:
///
///         L2_NONCE=$(cast nonce $DEPLOYER --rpc-url $L2_RPC)
///         L2_BRIDGE_PREDICTED=$(cast compute-address $DEPLOYER --nonce $L2_NONCE)
///
///      2. Deploy L1CGTBridge on L1 with the predicted L2 address:
///
///         forge script DeployCGTBridgeL1 \
///           --sig "run(address,uint8,address,address)" \
///           $L1_TOKEN $DECIMALS $L2_BRIDGE_PREDICTED $L1_MESSENGER \
///           --rpc-url $L1_RPC --broadcast
///
///      3. Deploy L2CGTBridge on L2 with the actual L1 address from step 2:
///
///         forge script DeployCGTBridgeL2 \
///           --sig "run(address,address,uint8,address)" \
///           $L1_BRIDGE $L2_MESSENGER $DECIMALS $LIQUIDITY_CONTROLLER \
///           --rpc-url $L2_RPC --broadcast
///
///      4. Verify the deployed L2 address matches the prediction from step 1.
///
///      5. Authorize the L2CGTBridge as a minter on LiquidityController
///         (must be called by the LiquidityController owner):
///
///         forge script DeployCGTBridgeL2 \
///           --sig "authorizeMinter(address,address)" \
///           $LIQUIDITY_CONTROLLER $L2_BRIDGE \
///           --rpc-url $L2_RPC --broadcast
///
///      The address coordination works because CREATE addresses depend only on
///      deployer + nonce, NOT on constructor args.
contract DeployCGTBridgeL1 is Script {
    /// @notice Deploys L1CGTBridge.
    /// @param _l1Token      Address of the L1 ERC-20 token to bridge.
    /// @param _tokenDecimals Decimal count of the L1 token (must be <= 18).
    /// @param _otherBridge   Address of the paired L2CGTBridge (already deployed on L2).
    /// @param _messenger     Address of the L1CrossDomainMessenger.
    /// @return bridge_ The deployed L1CGTBridge contract.
    function run(
        address _l1Token,
        uint8 _tokenDecimals,
        address _otherBridge,
        address _messenger
    )
        public
        returns (L1CGTBridge bridge_)
    {
        assertValidInput(_l1Token, _tokenDecimals, _otherBridge, _messenger);

        vm.broadcast(msg.sender);
        bridge_ = new L1CGTBridge(
            IERC20(_l1Token),
            _tokenDecimals,
            _otherBridge,
            ICrossDomainMessenger(_messenger)
        );

        console.log("=== L1CGTBridge Deployment ===");
        console.log("L1CGTBridge:", address(bridge_));
        console.log("L1 Token:", _l1Token);
        console.log("Token Decimals:", _tokenDecimals);
        console.log("Other Bridge (L2):", _otherBridge);
        console.log("Messenger:", _messenger);
        console.log("==============================");
    }

    /// @notice Validates the input parameters.
    function assertValidInput(
        address _l1Token,
        uint8 _tokenDecimals,
        address _otherBridge,
        address _messenger
    )
        internal
        pure
    {
        require(_l1Token != address(0), "DeployCGTBridgeL1: l1Token cannot be zero address");
        require(_otherBridge != address(0), "DeployCGTBridgeL1: otherBridge cannot be zero address");
        require(_messenger != address(0), "DeployCGTBridgeL1: messenger cannot be zero address");
        require(_tokenDecimals <= 18, "DeployCGTBridgeL1: token decimals must be <= 18");
    }
}

/// @title DeployCGTBridgeL2
/// @notice Deploys L2CGTBridge on L2 and provides a helper to authorize it as a minter.
///         See DeployCGTBridgeL1 for the full deployment workflow.
contract DeployCGTBridgeL2 is Script {
    /// @notice Deploys L2CGTBridge.
    /// @param _otherBridge         Address of the paired L1CGTBridge (predicted or deployed).
    /// @param _messenger           Address of the L2CrossDomainMessenger (typically 0x4200...07).
    /// @param _tokenDecimals       Decimal count of the L1 token (must be <= 18).
    /// @param _liquidityController Address of the LiquidityController predeploy (typically 0x4200...2a).
    /// @return bridge_ The deployed L2CGTBridge contract.
    function run(
        address _otherBridge,
        address _messenger,
        uint8 _tokenDecimals,
        address _liquidityController
    )
        public
        returns (L2CGTBridge bridge_)
    {
        assertValidInput(_otherBridge, _messenger, _tokenDecimals, _liquidityController);

        vm.broadcast(msg.sender);
        bridge_ = new L2CGTBridge(
            _otherBridge,
            ICrossDomainMessenger(_messenger),
            _tokenDecimals,
            ILiquidityController(_liquidityController)
        );

        console.log("=== L2CGTBridge Deployment ===");
        console.log("L2CGTBridge:", address(bridge_));
        console.log("Other Bridge (L1):", _otherBridge);
        console.log("Messenger:", _messenger);
        console.log("Token Decimals:", _tokenDecimals);
        console.log("LiquidityController:", _liquidityController);
        console.log("==============================");
    }

    /// @notice Authorizes a bridge as a minter on the LiquidityController.
    ///         Must be called by the LiquidityController owner.
    /// @param _liquidityController Address of the LiquidityController predeploy.
    /// @param _bridge              Address of the L2CGTBridge to authorize.
    function authorizeMinter(address _liquidityController, address _bridge) public {
        require(_liquidityController != address(0), "DeployCGTBridgeL2: liquidityController cannot be zero address");
        require(_bridge != address(0), "DeployCGTBridgeL2: bridge cannot be zero address");

        vm.broadcast(msg.sender);
        ILiquidityController(_liquidityController).authorizeMinter(_bridge);

        console.log("=== Minter Authorization ===");
        console.log("LiquidityController:", _liquidityController);
        console.log("Authorized Minter:", _bridge);
        console.log("============================");
    }

    /// @notice Validates the input parameters.
    function assertValidInput(
        address _otherBridge,
        address _messenger,
        uint8 _tokenDecimals,
        address _liquidityController
    )
        internal
        pure
    {
        require(_otherBridge != address(0), "DeployCGTBridgeL2: otherBridge cannot be zero address");
        require(_messenger != address(0), "DeployCGTBridgeL2: messenger cannot be zero address");
        require(_liquidityController != address(0), "DeployCGTBridgeL2: liquidityController cannot be zero address");
        require(_tokenDecimals <= 18, "DeployCGTBridgeL2: token decimals must be <= 18");
    }
}
