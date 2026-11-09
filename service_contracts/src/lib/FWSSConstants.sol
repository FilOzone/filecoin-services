// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

uint256 constant NO_PROVING_DEADLINE = 0;
uint64 constant CHALLENGES_PER_PROOF = 5;
uint256 constant COMMISSION_MAX_BPS = 10000; // 100% in basis points
// Mirror of PDPVerifier.INACTIVITY_WINDOW (lib/pdp/src/PDPVerifier.sol)
uint256 constant PDP_INACTIVITY_WINDOW = 86400;

/*
* Maximum extraData for createDataSet
* Supports: 10 metadata entries with max sizes; plus
*           1 Authorizer payload (perms + WebAuthn + P256 ~1024 bytes)
*/
uint256 constant MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE = 5120; // 5 KiB

/*
* Maximum extraData for schedulePieceRemovals
* Supports: legacy signature (160 bytes needed); or
*           1 Authorizer payload (perms + WebAuthn + P256 ~1024 bytes)
*/
uint256 constant MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE = 1024; // 1KiB

/*
* Maximum extraData for terminateService
* Supports: legacy signature (160 bytes needed); or
*           1 Authorizer payload (perms + WebAuthn + P256 ~512 bytes)
*/
uint256 constant MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE = 1024; // 1KiB

// Metadata size and count limits
uint256 constant MAX_KEY_LENGTH = 32;
uint256 constant MAX_VALUE_LENGTH = 96;
uint256 constant MAX_KEYS_PER_DATASET = 10;
uint256 constant MAX_KEYS_PER_PIECE = 3;
