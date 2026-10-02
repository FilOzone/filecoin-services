// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Extsload} from "../Extsload.sol";

/// @title ExtsloadModule
/// @notice Exposes raw FWSS storage reads for FilecoinWarmStorageServiceStateView and the state library.
contract ExtsloadModule is Extsload {}
