// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";

/// @title LibServiceLifecycleGuards
/// @notice Shared payment lifecycle checks for FWSS modules.
library LibServiceLifecycleGuards {
    /// @notice Reverts after the PDP payment rail's end epoch.
    function requirePaymentNotBeyondEndEpoch(uint256 dataSetId, uint256 pdpEndEpoch) internal view {
        if (pdpEndEpoch != 0) {
            require(
                block.number <= pdpEndEpoch, Errors.DataSetPaymentBeyondEndEpoch(dataSetId, pdpEndEpoch, block.number)
            );
        }
    }
}
