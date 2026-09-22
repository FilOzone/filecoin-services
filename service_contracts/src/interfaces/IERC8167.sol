// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

interface IERC8167 {
    event SelectorDelegated(bytes4 indexed selector, address indexed delegate);

    error FunctionNotFound(bytes4 selector);

    function implementation(bytes4 selector) external view returns (address);

    function selectors() external view returns (bytes4[] memory);
}
