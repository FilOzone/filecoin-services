// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {UD60x18, uEXP2_MAX_INPUT, uUNIT} from "@prb-math/UD60x18.sol";

/**
 * @dev Recurring dutch auction
 */
library Dutch {
    // Target 1 auction per week, on average
    uint256 public constant RESET_FACTOR = 4;
    uint256 public constant HALVING_INTERVAL = 3.5 days;

    uint256 public constant MAX_DECAY = uEXP2_MAX_INPUT * HALVING_INTERVAL / uUNIT;

    /**
     * @notice Exponential decay by 1/4 per week
     * @param startPrice The initial price in attoFIL at elapsed = 0
     * @param elapsed Seconds of time since the startPrice
     * @return price The decayed price in attoFIL
     */
    function decay(uint256 startPrice, uint256 elapsed) internal pure returns (uint256 price) {
        if (elapsed > MAX_DECAY) {
            return 0;
        }
        UD60x18 coefficient = UD60x18.wrap(startPrice);
        UD60x18 decayFactor = UD60x18.wrap(elapsed * uUNIT / HALVING_INTERVAL).exp2();

        return coefficient.div(decayFactor).unwrap();
    }
}
