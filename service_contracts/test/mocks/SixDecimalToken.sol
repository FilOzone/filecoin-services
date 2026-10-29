// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A USD stablecoin with six decimals; MockERC20 has 18.
contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six Decimal USD", "SIX") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
