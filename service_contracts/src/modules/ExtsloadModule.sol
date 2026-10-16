// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Extsload} from "../Extsload.sol";

/// @title ExtsloadModule
/// @notice Exposes raw FWSS storage reads for the state library and the legacy deployed view contract.
contract ExtsloadModule is Extsload {}
