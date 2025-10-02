// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * This token decreases the sender balance by more than the value parameter
 */
contract ExtraFeeToken is ERC20 {
    address private constant FEE_RECIPIENT = 0x0FeefeefeEFeeFeefeEFEEFEEfEeFEeFeeFeEfEe;
    uint256 public transferFee;

    constructor(uint256 _transferFee) ERC20("FeeToken", "FEE") {
        transferFee = _transferFee;
    }

    function setFeeBips(uint256 bips) public {
        transferFee = bips;
    }

    function mint(address to, uint256 value) public {
        _mint(to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        _transfer(msg.sender, FEE_RECIPIENT, transferFee);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        _transfer(from, FEE_RECIPIENT, transferFee);
        return true;
    }
}
