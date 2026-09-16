// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {IERC8167} from "./interfaces/IERC8167.sol";

abstract contract ERC8167Dispatcher is Proxy, IERC8167 {
    error SelectorAlreadyInstalled(bytes4 selector);
    error FixedSelector(bytes4 selector);
    error InvalidDelegate(address delegate);
    error DelegateUnchanged(bytes4 selector);

    address internal immutable dispatcherAddress = address(this);

    receive() external payable {
        revert FunctionNotFound(bytes4(0));
    }

    struct Route {
        address delegate;
        uint96 index;
    }

    /// @custom:storage-location erc7201:filecoin.storage.ERC8167
    struct RoutingStorage {
        mapping(bytes4 selector => Route) routes;
        bytes4[] selectors;
    }

    // keccak256(abi.encode(uint256(keccak256("filecoin.storage.ERC8167")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROUTING_STORAGE_LOCATION =
        0xf75f93fab7531bc992594a381e7bdc7e27ba70ebe4d39c930b3ca785836a6d00;

    function _routingStorage() internal pure returns (RoutingStorage storage state) {
        assembly {
            state.slot := ROUTING_STORAGE_LOCATION
        }
    }

    function _addRoute(bytes4 selector, address delegate) internal {
        require(!_isFixedSelector(selector), FixedSelector(selector));
        _checkDelegate(delegate);
        RoutingStorage storage state = _routingStorage();
        require(state.routes[selector].delegate == address(0), SelectorAlreadyInstalled(selector));
        state.routes[selector] = Route({delegate: delegate, index: uint96(state.selectors.length)});
        state.selectors.push(selector);
        emit SelectorDelegated(selector, delegate);
    }

    function _checkDelegate(address delegate) internal view {
        require(
            delegate != address(this) && delegate != dispatcherAddress && delegate.code.length != 0,
            InvalidDelegate(delegate)
        );
    }

    function _replaceRoute(bytes4 selector, address delegate) internal {
        require(!_isFixedSelector(selector), FixedSelector(selector));
        _checkDelegate(delegate);
        Route storage route = _routingStorage().routes[selector];
        require(route.delegate != address(0), FunctionNotFound(selector));
        require(route.delegate != delegate, DelegateUnchanged(selector));
        route.delegate = delegate;
        emit SelectorDelegated(selector, delegate);
    }

    function _removeRoute(bytes4 selector) internal {
        require(!_isFixedSelector(selector), FixedSelector(selector));
        RoutingStorage storage state = _routingStorage();
        Route memory route = state.routes[selector];
        require(route.delegate != address(0), FunctionNotFound(selector));
        bytes4 last = state.selectors[state.selectors.length - 1];
        state.selectors[route.index] = last;
        state.routes[last].index = route.index;
        state.selectors.pop();
        delete state.routes[selector];
        emit SelectorDelegated(selector, address(0));
    }

    function implementation(bytes4 selector) public view returns (address) {
        if (_isFixedSelector(selector)) {
            return dispatcherAddress;
        }
        return _routingStorage().routes[selector].delegate;
    }

    function selectors() public view returns (bytes4[] memory result) {
        bytes4[] memory fixedSelectors = _fixedSelectors();
        bytes4[] storage routedSelectors = _routingStorage().selectors;
        result = new bytes4[](fixedSelectors.length + routedSelectors.length);
        for (uint256 i; i < fixedSelectors.length; ++i) {
            result[i] = fixedSelectors[i];
        }
        for (uint256 i; i < routedSelectors.length; ++i) {
            result[fixedSelectors.length + i] = routedSelectors[i];
        }
    }

    function _isFixedSelector(bytes4 selector) internal pure returns (bool) {
        bytes4[] memory fixedSelectors = _fixedSelectors();
        for (uint256 i; i < fixedSelectors.length; ++i) {
            if (selector == fixedSelectors[i]) return true;
        }
        return false;
    }

    /// @dev Derived dispatchers must include every method they implement directly, including inherited methods.
    function _fixedSelectors() internal pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](2);
        result[0] = IERC8167.implementation.selector;
        result[1] = IERC8167.selectors.selector;
    }

    function _implementation() internal view override returns (address) {
        address delegate = _routingStorage().routes[msg.sig].delegate;
        require(delegate != address(0), FunctionNotFound(msg.sig));
        return delegate;
    }
}
