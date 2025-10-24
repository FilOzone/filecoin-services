// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

library BigEndian {
    function encode(uint256 decoded) internal pure returns (bytes memory encoded) {
        assembly ("memory-safe") {
            // binary search
            let size := shl(7, lt(0xffffffffffffffffffffffffffffffff, decoded))
            size := or(size, shl(6, lt(0xffffffffffffffff, shr(size, decoded))))
            size := or(size, shl(5, lt(0xffffffff, shr(size, decoded))))
            size := or(size, shl(4, lt(0xffff, shr(size, decoded))))
            size := or(size, shl(3, lt(0xff, shr(size, decoded))))
            size := add(shr(3, size), lt(0, shr(size, decoded)))

            encoded := mload(0x40)
            mstore(add(size, encoded), decoded)
            mstore(encoded, size)
            mstore(0x40, add(64, encoded))
        }
    }

    function decode(bytes memory encoded) internal pure returns (uint256 decoded) {
        assembly ("memory-safe") {
            decoded := shr(shl(3, sub(0x20, mload(encoded))), mload(add(encoded, 0x20)))
        }
    }
}
