// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";

import { DevnetMintableERC20 } from "src/DevnetMintableERC20.sol";

/// @title DeployDevnetMintableToken
/// @notice Deploys the test ERC-20 used by automated bridge deposit/withdraw tests.
contract DeployDevnetMintableToken is Script {
    function run(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _initialHolder,
        uint256 _initialSupply
    )
        external
        returns (DevnetMintableERC20 token_)
    {
        vm.broadcast(msg.sender);
        token_ = new DevnetMintableERC20(_name, _symbol, _decimals, _initialHolder, _initialSupply);

        console.log("=== DevnetMintableERC20 Deployment ===");
        console.log("Token:", address(token_));
        console.log("Name:", _name);
        console.log("Symbol:", _symbol);
        console.log("Decimals:", _decimals);
        console.log("Initial Holder:", _initialHolder);
        console.log("Initial Supply:", _initialSupply);
        console.log("======================================");
    }
}
