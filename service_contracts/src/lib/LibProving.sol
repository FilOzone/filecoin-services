// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

/// @title LibProving
/// @notice Shared proving-period calculations for FWSS modules.
library LibProving {
    /// @dev Maps an epoch to its proving period ID using exclusive-inclusive ranges.
    ///
    /// Proving periods use (start, end] ranges where the original activation epoch is a
    /// boundary marker (and not included in the first period).
    ///
    /// With activation at A and period length M:
    ///
    ///   Period 0: epochs (A, A+M]     i.e. A+1 through A+M
    ///   Period 1: epochs (A+M, A+2M]  i.e. A+M+1 through A+2M
    ///   Period N: epochs (A+N*M, A+(N+1)*M]
    ///
    /// The deadline for period N (the last epoch at which a proof can be submitted)
    /// is A + (N+1)*M, this also the last epoch counted in the period.
    ///
    /// Example with A=1000, M=2880:
    ///   Period 0: epochs 1001-3880, deadline 3880
    ///   Period 1: epochs 3881-6760, deadline 6760
    function provingPeriodForEpoch(uint256 activationEpoch, uint256 epoch, uint256 provingPeriodLength)
        internal
        pure
        returns (uint256)
    {
        if (activationEpoch == 0 || epoch <= activationEpoch) {
            return type(uint256).max; // Invalid period
        }
        // -1 converts from inclusive-exclusive to exclusive-inclusive ranges,
        // where the deadline epoch belongs to its own period rather than the next
        return (epoch - activationEpoch - 1) / provingPeriodLength;
    }

    /// @dev Returns the deadline epoch for a proving period. The last epoch at which a
    /// proof can be submitted and the last epoch IN that period. For period N with
    /// activation A and period length M: deadline = A + (N+1)*M.
    function calcPeriodDeadline(uint256 activationEpoch, uint256 periodId, uint256 maxProvingPeriod)
        internal
        pure
        returns (uint256)
    {
        return activationEpoch + (periodId + 1) * maxProvingPeriod;
    }
}
