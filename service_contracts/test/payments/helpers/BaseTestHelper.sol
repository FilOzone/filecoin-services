// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

contract BaseTestHelper is Test {
    uint256 internal ownerSk = 0x01;
    uint256 internal user1Sk = 0x11;
    uint256 internal user2Sk = 0x12;
    uint256 internal user3Sk = 0x13;
    uint256 internal operatorSk = 0x21;
    uint256 internal operator2Sk = 0x22;
    uint256 internal validatorSk = 0x31;
    uint256 internal serviceFeeRecipientSk = 0x41;
    uint256 internal relayerSk = 0x51;

    address public immutable OWNER = vm.addr(ownerSk);
    address public immutable USER1 = vm.addr(user1Sk);
    address public immutable USER2 = vm.addr(user2Sk);
    address public immutable USER3 = vm.addr(user3Sk);
    address public immutable OPERATOR = vm.addr(operatorSk);
    address public immutable OPERATOR2 = vm.addr(operator2Sk);
    address public immutable VALIDATOR = vm.addr(validatorSk);
    address public immutable SERVICE_FEE_RECIPIENT = vm.addr(serviceFeeRecipientSk);
    address public immutable RELAYER = vm.addr(relayerSk);
}
