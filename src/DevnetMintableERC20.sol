// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DevnetMintableERC20
/// @notice Minimal ERC-20 for repeatable devnet bridge tests.
/// @dev Anyone can mint in this test token. Do not use in production.
contract DevnetMintableERC20 is ERC20 {
    uint8 internal immutable TOKEN_DECIMALS_;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _initialHolder,
        uint256 _initialSupply
    )
        ERC20(_name, _symbol)
    {
        require(_initialHolder != address(0), "DevnetMintableERC20: initialHolder zero");
        require(_decimals < 18, "DevnetMintableERC20: decimals must be < 18");
        TOKEN_DECIMALS_ = _decimals;
        _mint(_initialHolder, _initialSupply);
    }

    function decimals() public view override returns (uint8) {
        return TOKEN_DECIMALS_;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
