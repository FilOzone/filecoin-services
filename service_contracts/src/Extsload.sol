// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

contract Extsload {
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 32)
        }
    }

    function extsloadStruct(bytes32 slot, uint256 size) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            mstore(0, 0x20)
            mstore(0x20, size)
            let retPos := 0x40
            for {} size {} {
                mstore(retPos, sload(slot))
                slot := add(1, slot)
                retPos := add(32, retPos)
                size := sub(size, 1)
            }
            return(0, retPos)
        }
    }
}
