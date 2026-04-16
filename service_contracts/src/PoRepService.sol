// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FVMAddress} from "@fvm-solidity/FVMAddress.sol";
import {FVMMiner} from "@fvm-solidity/FVMMiner.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepDeal} from "./PoRepDeal.sol";

contract PoRepPayee {
    using FVMAddress for address;
    using FVMMiner for uint64;

    error Unauthorized(address caller);

    uint64 public immutable MINER;

    constructor() {
        MINER = PoRepService(msg.sender).getMiner();
    }

    function owner() public view returns (uint64) {
        return MINER.getOwnerActorId();
    }

    function sudo(address payable, bytes calldata) external payable returns (bytes memory) {
        require(msg.sender.actorId() == owner(), Unauthorized(msg.sender));
        assembly ("memory-safe") {
            let insize := calldataload(68)
            calldatacopy(0, 100, insize)
            let success := call(gas(), calldataload(4), callvalue(), 0, insize, 0, 0)
            mstore(0, 32)
            mstore(32, returndatasize())
            returndatacopy(64, 0, returndatasize())
            if success { return(0, add(64, returndatasize())) }
            revert(0, add(64, returndatasize()))
        }
    }
}

contract PoRepService {
    FilecoinPayV1 private immutable PAYMENTS;

    constructor(FilecoinPayV1 payments) {
        PAYMENTS = payments;
    }

    function getMiner() external view returns (uint64 payee) {
        assembly ("memory-safe") {
            payee := tload(0)
        }
    }

    function setMiner(uint64 payee) internal {
        assembly ("memory-safe") {
            tstore(0, payee)
        }
    }

    bytes32 constant RECEIVER_INITCODE_HASH = keccak256(type(PoRepPayee).creationCode);

    function getReceiverAddress(uint64 provider) public view returns (address receiver) {
        receiver = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            uint8(0xff), address(this), bytes32(uint256(uint64(provider))), RECEIVER_INITCODE_HASH
                        )
                    )
                )
            )
        );
    }

    function createReceiver(uint64 provider) public returns (address receiver) {
        receiver = getReceiverAddress(provider);
        if (receiver.code.length == 0) {
            setMiner(provider);
            new PoRepPayee{salt: bytes32(uint256(provider))}();
        }
    }

    function createDeal(address client, uint64 provider) external returns (address deal) {
        address receiver = createReceiver(provider);

        deal = address(new PoRepDeal(address(this), client, provider, receiver, PAYMENTS));
    }
}
