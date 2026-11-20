// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

/// @notice Payment a FilecoinPayV2 PDP rail settled for epochs (fromEpoch, toEpoch] whose proving period was still
/// open. It stays in the rail's available balance until the period resolves.
struct HeldPayment {
    uint128 amount;
    uint64 fromEpoch;
    uint64 toEpoch;
}

library LibHeldPayments {
    // ERC-7201 namespace: filecoin.FWSS.HeldPayments
    // keccak256(abi.encode(uint256(keccak256("filecoin.FWSS.HeldPayments")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x1cb660a530c61d144f545853cc85a77e4fb7409e2c07b86dee58c778f1a77e00;

    /// @custom:storage-location erc7201:filecoin.FWSS.HeldPayments
    struct Storage {
        mapping(uint256 railId => HeldPayment) held;
    }

    function get(uint256 railId) internal view returns (HeldPayment memory) {
        return _storage().held[railId];
    }

    function set(uint256 railId, uint256 amount, uint256 fromEpoch, uint256 toEpoch) internal {
        _storage().held[railId] =
            HeldPayment({amount: uint128(amount), fromEpoch: uint64(fromEpoch), toEpoch: uint64(toEpoch)});
    }

    function clear(uint256 railId) internal {
        delete _storage().held[railId];
    }

    function _storage() private pure returns (Storage storage $) {
        assembly ("memory-safe") {
            $.slot := STORAGE_LOCATION
        }
    }
}
