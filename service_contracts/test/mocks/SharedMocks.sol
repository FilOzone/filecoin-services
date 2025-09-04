// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PDPListener} from "@pdp/PDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Mock implementation of the USDFC token
contract MockERC20 is IERC20, IERC20Metadata {
    string private _name = "USD Filecoin";
    string private _symbol = "USDFC";
    uint8 private _decimals = 6;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor() {
        _mint(msg.sender, 1000000 * 10 ** _decimals); // Mint 1 million tokens to deployer
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

// MockPDPVerifier is used to simulate the PDPVerifier for our tests
contract MockPDPVerifier {
    uint256 public nextDataSetId = 1;

    // Track data set service providers for testing
    mapping(uint256 => address) public dataSetServiceProviders;

    event DataSetCreated(uint256 indexed setId, address indexed owner);
    event DataSetServiceProviderChanged(
        uint256 indexed setId, address indexed oldServiceProvider, address indexed newServiceProvider
    );
    event DataSetDeleted(uint256 indexed setId, uint256 deletedLeafCount);

    // Basic implementation to create data sets and call the listener
    function createDataSet(PDPListener listenerAddr, bytes calldata extraData) public payable returns (uint256) {
        uint256 setId = nextDataSetId++;

        // Call the listener if specified
        if (listenerAddr != PDPListener(address(0))) {
            listenerAddr.dataSetCreated(setId, msg.sender, extraData);
        }

        // Track service provider
        dataSetServiceProviders[setId] = msg.sender;

        emit DataSetCreated(setId, msg.sender);
        return setId;
    }

    function deleteDataSet(address listenerAddr, uint256 setId, bytes calldata extraData) public {
        if (listenerAddr != address(0)) {
            PDPListener(listenerAddr).dataSetDeleted(setId, 0, extraData);
        }

        delete dataSetServiceProviders[setId];
        emit DataSetDeleted(setId, 0);
    }

    function addPieces(
        PDPListener listenerAddr,
        uint256 dataSetId,
        uint256 firstAdded,
        Cids.Cid[] memory pieceData,
        bytes memory signature,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) public {
        // Convert to per-piece format: each piece gets same metadata
        string[][] memory allKeys = new string[][](pieceData.length);
        string[][] memory allValues = new string[][](pieceData.length);
        for (uint256 i = 0; i < pieceData.length; i++) {
            allKeys[i] = metadataKeys;
            allValues[i] = metadataValues;
        }

        bytes memory extraData = abi.encode(signature, allKeys, allValues);
        listenerAddr.piecesAdded(dataSetId, firstAdded, pieceData, extraData);
    }

    /**
     * @notice Simulates service provider change for testing purposes
     * @dev This function mimics the PDPVerifier's claimDataSetOwnership functionality
     * @param dataSetId The ID of the data set
     * @param newServiceProvider The new service provider address
     * @param listenerAddr The listener contract address
     * @param extraData Additional data to pass to the listener
     */
    function changeDataSetServiceProvider(
        uint256 dataSetId,
        address newServiceProvider,
        address listenerAddr,
        bytes calldata extraData
    ) external {
        require(dataSetServiceProviders[dataSetId] != address(0), "Data set does not exist");
        require(newServiceProvider != address(0), "New service provider cannot be zero address");

        address oldServiceProvider = dataSetServiceProviders[dataSetId];
        require(
            oldServiceProvider != newServiceProvider,
            "New service provider must be different from current service provider"
        );

        // Update service provider
        dataSetServiceProviders[dataSetId] = newServiceProvider;

        // Call the listener's storageProviderChanged function
        if (listenerAddr != address(0)) {
            PDPListener(listenerAddr).storageProviderChanged(
                dataSetId, oldServiceProvider, newServiceProvider, extraData
            );
        }

        emit DataSetServiceProviderChanged(dataSetId, oldServiceProvider, newServiceProvider);
    }

    function forceSetServiceProvider(uint256 dataSetId, address newProvider) external {
        dataSetServiceProviders[dataSetId] = newProvider;
    }

    function piecesScheduledRemove(
        uint256 dataSetId,
        uint256[] memory pieceIds,
        address listenerAddr,
        bytes calldata extraData
    ) external {
        if (listenerAddr != address(0)) {
            PDPListener(listenerAddr).piecesScheduledRemove(dataSetId, pieceIds, extraData);
        }
    }
}
