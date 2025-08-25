// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console, Vm} from "forge-std/Test.sol";
import {PDPListener, PDPVerifier} from "@pdp/PDPVerifier.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Cids} from "@pdp/Cids.sol";
import {Payments, IValidator} from "@fws-payments/Payments.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IPDPTypes} from "@pdp/interfaces/IPDPTypes.sol";
import {Errors} from "../src/Errors.sol";

import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";

import {FilecoinWarmStorageServiceStateInternalLibrary} from
    "../src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";


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

    function addPieces(
        PDPListener listenerAddr,
        uint256 dataSetId,
        uint256 firstAdded,
        Cids.Cid[] memory pieceData,
        bytes memory signature,
        string memory metadata
    ) public {
        bytes memory extraData = abi.encode(signature, metadata);

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

    /**
     * @notice Get the current service provider of a data set
     * @param dataSetId The ID of the data set
     * @return The current service provider address
     */
    function getDataSetServiceProvider(uint256 dataSetId) external view returns (address) {
        return dataSetServiceProviders[dataSetId];
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

contract FilecoinWarmStorageServiceTest is Test {
    // Testing Constants
    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    // Contracts
    FilecoinWarmStorageService public pdpServiceWithPayments;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public registry;

    // Test accounts
    address public deployer;
    address public client;
    address public serviceProvider;
    address public filCDN;

    address public sp1;
    address public sp2;
    address public sp3;

    // Test parameters
    bytes public extraData;

    // Events from Payments contract to verify
    event RailCreated(
        uint256 indexed railId,
        address indexed payer,
        address indexed payee,
        address token,
        address operator,
        address validator,
        address serviceFeeRecipient,
        uint256 commissionRateBps
    );

    // Service provider change event to verify
    event DataSetServiceProviderChanged(
        uint256 indexed dataSetId, address indexed oldServiceProvider, address indexed newServiceProvider
    );

    function setUp() public {
        // Setup test accounts
        deployer = address(this);
        client = address(0xf1);
        serviceProvider = address(0xf2);
        filCDN = address(0xf3);

        // Additional accounts for registry tests
        sp1 = address(0xf4);
        sp2 = address(0xf5);
        sp3 = address(0xf6);

        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(client, 100 ether);
        vm.deal(serviceProvider, 100 ether);
        vm.deal(sp1, 100 ether);
        vm.deal(sp2, 100 ether);
        vm.deal(sp3, 100 ether);
        vm.deal(address(0xf10), 100 ether);
        vm.deal(address(0xf11), 100 ether);
        vm.deal(address(0xf12), 100 ether);
        vm.deal(address(0xf13), 100 ether);
        vm.deal(address(0xf14), 100 ether);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        registry = ServiceProviderRegistry(address(registryProxy));

        // Register service providers in the registry
        vm.prank(serviceProvider);
        registry.registerProvider{value: 1 ether}(
            "Service Provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp1);
        registry.registerProvider{value: 1 ether}(
            "SP1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp2);
        registry.registerProvider{value: 1 ether}(
            "SP2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp2.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether
                })
            ),
            new string[](0),
            new string[](0)
        );

        vm.prank(sp3);
        registry.registerProvider{value: 1 ether}(
            "SP3",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://sp3.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Transfer tokens to client for payment
        mockUSDFC.transfer(client, 10000 * 10 ** mockUSDFC.decimals());

        // Deploy FilecoinWarmStorageService with proxy
        FilecoinWarmStorageService pdpServiceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier), address(payments), address(mockUSDFC), filCDN, address(registry)
        );
        bytes memory initializeData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy pdpServiceProxy = new MyERC1967Proxy(address(pdpServiceImpl), initializeData);
        pdpServiceWithPayments = FilecoinWarmStorageService(address(pdpServiceProxy));

        // Add providers to approved list
        pdpServiceWithPayments.addApprovedProvider(1); // serviceProvider
        pdpServiceWithPayments.addApprovedProvider(2); // sp1
        pdpServiceWithPayments.addApprovedProvider(3); // sp2
        pdpServiceWithPayments.addApprovedProvider(4); // sp3
    }

    function makeSignaturePass(address signer) public {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""), // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function testInitialState() public view {
        assertEq(
            pdpServiceWithPayments.pdpVerifierAddress(),
            address(mockPDPVerifier),
            "PDP verifier address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.paymentsContractAddress(),
            address(payments),
            "Payments contract address should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.usdfcTokenAddress(),
            address(mockUSDFC),
            "USDFC token address should be set correctly"
        );
        assertEq(pdpServiceWithPayments.filCDNAddress(), filCDN, "FilCDN address should be set correctly");
        assertEq(
            pdpServiceWithPayments.serviceCommissionBps(),
            0, // 0%
            "Service commission should be set correctly"
        );
        assertEq(pdpServiceWithPayments.getMaxProvingPeriod(), 2880, "Max proving period should be set correctly");
        assertEq(pdpServiceWithPayments.challengeWindow(), 60, "Challenge window size should be set correctly");
        assertEq(
            pdpServiceWithPayments.getMaxProvingPeriod(),
            2880,
            "Max proving period storage variable should be set correctly"
        );
        assertEq(
            pdpServiceWithPayments.challengeWindow(),
            60,
            "Challenge window size storage variable should be set correctly"
        );
    }

    function testCreateDataSetCreatesRailAndChargesFee() public {
        // Prepare ExtraData
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: true
        });

        // Encode the extra data
        extraData = abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for the one-time fee
        uint256 depositAmount = 1e6; // 10x the required fee
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        // Get account balances before creating data set
        (uint256 clientFundsBefore,) = getAccountInfo(address(mockUSDFC), client);
        (uint256 spFundsBefore,) = getAccountInfo(address(mockUSDFC), serviceProvider);

        // Expect RailCreated event when creating the data set
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetRailsCreated(1, 1, 1, 2, 3, client, serviceProvider, true);

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfo memory dataSet = pdpServiceWithPayments.getDataSet(newDataSetId);
        uint256 pdpRailId = dataSet.pdpRailId;
        uint256 cacheMissRailId = dataSet.cacheMissRailId;
        uint256 cdnRailId = dataSet.cdnRailId;

        // Verify valid rail IDs were created
        assertTrue(pdpRailId > 0, "PDP Rail ID should be non-zero");
        assertTrue(cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(cdnRailId > 0, "CDN Rail ID should be non-zero");

        // Verify data set info was stored correctly
        assertEq(dataSet.payer, client, "Payer should be set to client");
        assertEq(dataSet.payee, serviceProvider, "Payee should be set to service provider");

        // Verify metadata was stored correctly
        assertEq(dataSet.metadata, "Test Data Set", "Metadata should be stored correctly");

        // Verify client data set ids
        uint256[] memory clientDataSetIds = pdpServiceWithPayments.clientDataSets(client);
        assertEq(clientDataSetIds.length, 1);
        assertEq(clientDataSetIds[0], newDataSetId);

        assertEq(pdpServiceWithPayments.railToDataSet(pdpRailId), newDataSetId);
        assertEq(pdpServiceWithPayments.railToDataSet(cdnRailId), newDataSetId);

        // Verify data set info
        FilecoinWarmStorageService.DataSetInfo memory dataSetInfo = pdpServiceWithPayments.getDataSet(newDataSetId);
        assertEq(dataSetInfo.pdpRailId, pdpRailId, "PDP rail ID should match");
        assertNotEq(dataSetInfo.cacheMissRailId, 0, "Cache miss rail ID should be set");
        assertNotEq(dataSetInfo.cdnRailId, 0, "CDN rail ID should be set");
        assertEq(dataSetInfo.payer, client, "Payer should match");
        assertEq(dataSetInfo.payee, serviceProvider, "Payee should match");
        assertEq(dataSetInfo.withCDN, true, "withCDN should be true");

        // Verify withCDN was stored correctly
        assertTrue(dataSet.withCDN, "withCDN should be true");

        // Verify the rails in the actual Payments contract
        Payments.RailView memory pdpRail = payments.getRail(pdpRailId);
        assertEq(pdpRail.token, address(mockUSDFC), "Token should be USDFC");
        assertEq(pdpRail.from, client, "From address should be client");
        assertEq(pdpRail.to, serviceProvider, "To address should be service provider");
        assertEq(pdpRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(pdpRail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(pdpRail.commissionRateBps, 0, "No commission");
        assertEq(pdpRail.lockupFixed, 0, "Lockup fixed should be 0 after one-time payment");
        assertEq(pdpRail.paymentRate, 0, "Initial payment rate should be 0");

        Payments.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);
        assertEq(cacheMissRail.token, address(mockUSDFC), "Token should be USDFC");
        assertEq(cacheMissRail.from, client, "From address should be client");
        assertEq(cacheMissRail.to, serviceProvider, "To address should be service provider");
        assertEq(cacheMissRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cacheMissRail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(cacheMissRail.commissionRateBps, 0, "No commission");
        assertEq(cacheMissRail.lockupFixed, 0, "Lockup fixed should be 0 after one-time payment");
        assertEq(cacheMissRail.paymentRate, 0, "Initial payment rate should be 0");

        Payments.RailView memory cdnRail = payments.getRail(cdnRailId);
        assertEq(cdnRail.token, address(mockUSDFC), "Token should be USDFC");
        assertEq(cdnRail.from, client, "From address should be client");
        assertEq(cdnRail.to, filCDN, "To address should be FilCDN");
        assertEq(cdnRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cdnRail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(cdnRail.commissionRateBps, 0, "No commission");
        assertEq(cdnRail.lockupFixed, 0, "Lockup fixed should be 0 after one-time payment");
        assertEq(cdnRail.paymentRate, 0, "Initial payment rate should be 0");

        // Get account balances after creating data set
        (uint256 clientFundsAfter,) = getAccountInfo(address(mockUSDFC), client);
        (uint256 spFundsAfter,) = getAccountInfo(address(mockUSDFC), serviceProvider);

        // Calculate expected client balance
        uint256 expectedClientFundsAfter = clientFundsBefore - 1e5;

        // Verify balances changed correctly (one-time fee transferred)
        assertEq(
            clientFundsAfter, expectedClientFundsAfter, "Client funds should decrease by the data set creation fee"
        );
        assertTrue(spFundsAfter > spFundsBefore, "Service provider funds should increase");
    }

    function testCreateDataSetNoCDN() public {
        // Prepare ExtraData
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: false
        });

        // Encode the extra data
        extraData = abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the Payments contract for the one-time fee
        uint256 depositAmount = 1e6; // 10x the required fee
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        // Expect RailCreated event when creating the data set
        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.DataSetRailsCreated(1, 1, 1, 0, 0, client, serviceProvider, false);

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfo memory dataSet = pdpServiceWithPayments.getDataSet(newDataSetId);

        // Verify withCDN was stored correctly
        assertFalse(dataSet.withCDN, "withCDN should be false");

        // Verify the commission rate was set correctly for basic service (no CDN)
        Payments.RailView memory pdpRail = payments.getRail(dataSet.pdpRailId);
        assertEq(pdpRail.commissionRateBps, 0, "Commission rate should be 0% for basic service (no CDN)");

        assertEq(dataSet.cacheMissRailId, 0, "Cache miss rail ID should be 0 for basic service (no CDN)");
        assertEq(dataSet.cdnRailId, 0, "CDN rail ID should be 0 for basic service (no CDN)");
    }

    function testCreateDataSetAddPieces() public {
        bool withCDN = false;
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: "Test Data Set",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: withCDN
        });
        bytes memory encodedCreateData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        vm.startPrank(client);
        // Set operator approval for the PDP service in the Payments contract
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true, // approved
            1000e6, // rate allowance (1000 USDFC)
            1000e6, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        uint256 depositAmount = 1e6; // 10x the required fee
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        makeSignaturePass(client);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedCreateData);

        uint256 firstAdded = 0;
        string memory metadataShort = "metadata";
        string memory metadataLong = "metadatAmetadaTametadAtametaDatametAdatameTadatamEtadataMetadata";
        Cids.Cid[] memory pieceData1 = new Cids.Cid[](3);
        pieceData1[0].data = bytes("1_0:1111");
        pieceData1[1].data = bytes("1_1:111100000");
        pieceData1[2].data = bytes("1_2:11110000000000");
        Cids.Cid[] memory pieceData2 = new Cids.Cid[](2);
        pieceData2[0].data = bytes("2_0:22222222222222222222");
        pieceData2[1].data = bytes("2_1:222222222222222222220000000000000000000000000000000000000000");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 0), "");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 1), "");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 2), "");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 3), "");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 4), "");
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData1, FAKE_SIGNATURE, metadataShort
        );
        firstAdded += pieceData1.length;
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 0), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 1), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 2), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 3), "");
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 4), "");
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieceData2, FAKE_SIGNATURE, metadataLong
        );
        firstAdded += pieceData2.length;
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 0), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 1), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 2), metadataShort);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 3), metadataLong);
        assertEq(pdpServiceWithPayments.getPieceMetadata(dataSetId, 4), metadataLong);
    }

    // Helper function to get account info from the Payments contract
    function getAccountInfo(address token, address owner)
        internal
        view
        returns (uint256 funds, uint256 lockupCurrent)
    {
        (funds, lockupCurrent,,) = payments.accounts(token, owner);
        return (funds, lockupCurrent);
    }

    // Constants for calculations
    uint256 constant COMMISSION_MAX_BPS = 10000;

    function testGlobalParameters() public view {
        // These parameters should be the same as in SimplePDPService
        assertEq(pdpServiceWithPayments.getMaxProvingPeriod(), 2880, "Max proving period should be 2880 epochs");
        assertEq(pdpServiceWithPayments.challengeWindow(), 60, "Challenge window should be 60 epochs");
    }

    // ===== Pricing Tests =====

    function testGetServicePriceValues() public view {
        // Test the values returned by getServicePrice
        FilecoinWarmStorageService.ServicePricing memory pricing = pdpServiceWithPayments.getServicePrice();

        uint256 decimals = 6; // MockUSDFC uses 6 decimals in tests
        uint256 expectedNoCDN = 2 * 10 ** decimals; // 2 USDFC with 6 decimals
        uint256 expectedWithCDN = 25 * 10 ** (decimals - 1); // 2.5 USDFC with 6 decimals

        assertEq(pricing.pricePerTiBPerMonthNoCDN, expectedNoCDN, "No CDN price should be 2 * 10^decimals");
        assertEq(pricing.pricePerTiBPerMonthWithCDN, expectedWithCDN, "With CDN price should be 2.5 * 10^decimals");
        assertEq(pricing.tokenAddress, address(mockUSDFC), "Token address should match USDFC");
        assertEq(pricing.epochsPerMonth, 86400, "Epochs per month should be 86400");

        // Verify the values are in expected range
        assert(pricing.pricePerTiBPerMonthNoCDN < 10 ** 8); // Less than 10^8
        assert(pricing.pricePerTiBPerMonthWithCDN < 10 ** 8); // Less than 10^8
    }

    function testGetEffectiveRatesValues() public view {
        // Test the values returned by getEffectiveRates
        (uint256 serviceFee, uint256 spPayment) = pdpServiceWithPayments.getEffectiveRates();

        uint256 decimals = 6; // MockUSDFC uses 6 decimals in tests
        // Total is 2 USDFC with 6 decimals
        uint256 expectedTotal = 2 * 10 ** decimals;

        // Test setup uses 0% commission
        uint256 expectedServiceFee = 0; // 0% commission
        uint256 expectedSpPayment = expectedTotal; // 100% goes to SP

        assertEq(serviceFee, expectedServiceFee, "Service fee should be 0 with 0% commission");
        assertEq(spPayment, expectedSpPayment, "SP payment should be 2 * 10^6");
        assertEq(serviceFee + spPayment, expectedTotal, "Total should equal 2 * 10^6");

        // Verify the values are in expected range
        assert(serviceFee + spPayment < 10 ** 8); // Less than 10^8
    }

    // ===== Client-Data Set Tracking Tests =====
    function createDataSetForClient(address provider, address clientAddress, string memory metadata)
        internal
        returns (uint256)
    {
        // Prepare extra data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: metadata,
            payer: clientAddress,
            withCDN: false,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(address(mockUSDFC), clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
    }

    function testGetClientDataSets_EmptyClient() public view {
        // Test with a client that has no data sets
        FilecoinWarmStorageService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        assertEq(dataSets.length, 0, "Should return empty array for client with no data sets");
    }

    function testGetClientDataSets_SingleDataSet() public {
        // Create a single data set for the client
        string memory metadata = "Test metadata";

        createDataSetForClient(sp1, client, metadata);

        // Get data sets
        FilecoinWarmStorageService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 1, "Should return one data set");
        assertEq(dataSets[0].payer, client, "Payer should match");
        assertEq(dataSets[0].payee, sp1, "Payee should match");
        assertEq(dataSets[0].metadata, metadata, "Metadata should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");
        assertGt(dataSets[0].pdpRailId, 0, "Rail ID should be set");
    }

    function testGetClientDataSets_MultipleDataSets() public {
        // Create multiple data sets for the client
        createDataSetForClient(sp1, client, "Metadata 1");
        createDataSetForClient(sp2, client, "Metadata 2");

        // Get data sets
        FilecoinWarmStorageService.DataSetInfo[] memory dataSets = pdpServiceWithPayments.getClientDataSets(client);

        // Verify results
        assertEq(dataSets.length, 2, "Should return two data sets");

        // Check first data set
        assertEq(dataSets[0].payer, client, "First data set payer should match");
        assertEq(dataSets[0].payee, sp1, "First data set payee should match");
        assertEq(dataSets[0].metadata, "Metadata 1", "First data set metadata should match");
        assertEq(dataSets[0].clientDataSetId, 0, "First data set ID should be 0");

        // Check second data set
        assertEq(dataSets[1].payer, client, "Second data set payer should match");
        assertEq(dataSets[1].payee, sp2, "Second data set payee should match");
        assertEq(dataSets[1].metadata, "Metadata 2", "Second data set metadata should match");
        assertEq(dataSets[1].clientDataSetId, 1, "Second data set ID should be 1");
    }

    // ===== Data Set Service Provider Change Tests =====

    /**
     * @notice Helper function to create a data set and return its ID
     * @dev This function sets up the necessary state for service provider change testing
     * @param provider The service provider address
     * @param clientAddress The client address
     * @param metadata The data set metadata
     * @return The created data set ID
     */
    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory metadata)
        internal
        returns (uint256)
    {
        // Prepare extra data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: metadata,
            payer: clientAddress,
            withCDN: false,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(
            address(mockUSDFC), address(pdpServiceWithPayments), true, 1000e6, 1000e6, 365 days
        );
        mockUSDFC.approve(address(payments), 100e6);
        payments.deposit(address(mockUSDFC), clientAddress, 100e6);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
    }

    /**
     * @notice Test successful service provider change between two approved providers
     * @dev Verifies only the data set's payee is updated, event is emitted, and registry state is unchanged.
     */
    function testServiceProviderChangedSuccessDecoupled() public {
        // Create a data set with sp1 as the service provider
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");

        // Change service provider from sp1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit DataSetServiceProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);

        // Only the data set's payee is updated
        FilecoinWarmStorageService.DataSetInfo memory dataSet = pdpServiceWithPayments.getDataSet(testDataSetId);
        assertEq(dataSet.payee, sp2, "Payee should be updated to new service provider");
    }

    /**
     * @notice Test service provider change reverts if new service provider is not an approved provider
     */
    function testServiceProviderChangedNoLongerChecksApproval() public {
        // Create a data set with sp1 as the service provider
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        address newProvider = address(0x9999);
        bytes memory testExtraData = new bytes(0);
        vm.prank(newProvider);
        mockPDPVerifier.changeDataSetServiceProvider(
            testDataSetId, newProvider, address(pdpServiceWithPayments), testExtraData
        );
        // Verify the change succeeded
        FilecoinWarmStorageService.DataSetInfo memory dataSet = pdpServiceWithPayments.getDataSet(testDataSetId);
        assertEq(dataSet.payee, newProvider, "Payee should be updated to new service provider");
    }

    /**
     * @notice Test service provider change reverts if new service provider is zero address
     */
    function testServiceProviderChangedRevertsIfNewServiceProviderZeroAddress() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        vm.prank(sp1);
        vm.expectRevert("New service provider cannot be zero address");
        mockPDPVerifier.changeDataSetServiceProvider(
            testDataSetId, address(0), address(pdpServiceWithPayments), testExtraData
        );
    }

    /**
     * @notice Test service provider change reverts if old service provider mismatch
     */
    function testServiceProviderChangedRevertsIfOldServiceProviderMismatch() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as PDPVerifier with wrong old service provider
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.OldServiceProviderMismatch.selector, 1, sp1, sp2));
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp2, sp2, testExtraData);
    }

    /**
     * @notice Test service provider change reverts if called by unauthorized address
     */
    function testServiceProviderChangedRevertsIfUnauthorizedCaller() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as sp2 (not PDPVerifier)
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), sp2));
        pdpServiceWithPayments.storageProviderChanged(testDataSetId, sp1, sp2, testExtraData);
    }

    /**
     * @notice Test multiple data sets per provider: only the targeted data set's payee is updated
     */
    function testMultipleDataSetsPerProviderServiceProviderChange() public {
        // Create two data sets for sp1
        uint256 ps1 = createDataSetForServiceProviderTest(sp1, client, "Data Set 1");
        uint256 ps2 = createDataSetForServiceProviderTest(sp1, client, "Data Set 2");
        // Change service provider of ps1 to sp2
        bytes memory testExtraData = new bytes(0);
        vm.expectEmit(true, true, true, true);
        emit DataSetServiceProviderChanged(ps1, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(ps1, sp2, address(pdpServiceWithPayments), testExtraData);
        // ps1 payee updated, ps2 payee unchanged
        FilecoinWarmStorageService.DataSetInfo memory dataSet1 = pdpServiceWithPayments.getDataSet(ps1);
        FilecoinWarmStorageService.DataSetInfo memory dataSet2 = pdpServiceWithPayments.getDataSet(ps2);
        assertEq(dataSet1.payee, sp2, "ps1 payee should be sp2");
        assertEq(dataSet2.payee, sp1, "ps2 payee should remain sp1");
    }

    /**
     * @notice Test service provider change works with arbitrary extra data
     */
    function testServiceProviderChangedWithArbitraryExtraData() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        // Use arbitrary extra data
        bytes memory testExtraData = abi.encode("arbitrary", 123, address(this));
        vm.expectEmit(true, true, true, true);
        emit DataSetServiceProviderChanged(testDataSetId, sp1, sp2);
        vm.prank(sp2);
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);
        FilecoinWarmStorageService.DataSetInfo memory dataSet = pdpServiceWithPayments.getDataSet(testDataSetId);
        assertEq(dataSet.payee, sp2, "Payee should be updated to new service provider");
    }

    // ============= Data Set Payment Termination Tests =============

    function testTerminateServiceLifecycle() public {
        console.log("=== Test: Data Set Payment Termination Lifecycle ===");

        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        // Prepare data set creation data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadata: "Test Data Set for Termination",
            payer: client,
            signature: FAKE_SIGNATURE,
            withCDN: true // CDN enabled
        });

        bytes memory encodedData =
            abi.encode(createData.metadata, createData.payer, createData.withCDN, createData.signature);

        // Setup client payment approval and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(mockUSDFC),
            address(pdpServiceWithPayments),
            true,
            1000e6, // rate allowance
            1000e6, // lockup allowance
            365 days // max lockup period
        );
        uint256 depositAmount = 100e6;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(address(mockUSDFC), client, depositAmount);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        uint256 maxProvingPeriod = pdpServiceWithPayments.getMaxProvingPeriod();
        uint256 challengeWindow = pdpServiceWithPayments.challengeWindow();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, challengeEpoch, 100, "");

        assertEq(pdpServiceWithPayments.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = pdpServiceWithPayments.provingDeadlines(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            pdpServiceWithPayments.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            pdpServiceWithPayments.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        // 3. Terminate payment
        console.log("\n3. Terminating payment rails");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        pdpServiceWithPayments.terminateService(dataSetId);

        // 4. Assertions
        // Check paymentEndEpoch is set
        FilecoinWarmStorageService.DataSetInfo memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertTrue(info.paymentEndEpoch > 0, "paymentEndEpoch should be set after termination");
        console.log("Payment termination successful. Payment end epoch:", info.paymentEndEpoch);

        // Ensure piecesAdded reverts
        console.log("\n4. Testing operations after termination");
        console.log("Testing piecesAdded - should revert (payment terminated)");
        vm.prank(address(mockPDPVerifier));
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        bytes32 pieceData = hex"010203";
        pieces[0] = Cids.CommPv2FromDigest(0, 4, pieceData);
        bytes memory addPiecesExtraData = abi.encode(FAKE_SIGNATURE, "some metadata");
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetPaymentAlreadyTerminated.selector, dataSetId));
        pdpServiceWithPayments.piecesAdded(dataSetId, 0, pieces, addPiecesExtraData);
        console.log("[OK] piecesAdded correctly reverted after termination");

        // Wait for payment end epoch to elapse
        console.log("\n5. Rolling past payment end epoch");
        console.log("Current block:", block.number);
        console.log("Rolling to block:", info.paymentEndEpoch + 1);
        vm.roll(info.paymentEndEpoch + 1);

        // Ensure other functions also revert now
        console.log("\n6. Testing operations after payment end epoch");
        // piecesScheduledRemove
        console.log("Testing piecesScheduledRemove - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        bytes memory scheduleRemoveData = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.paymentEndEpoch, block.number
            )
        );
        mockPDPVerifier.piecesScheduledRemove(dataSetId, pieceIds, address(pdpServiceWithPayments), scheduleRemoveData);
        console.log("[OK] piecesScheduledRemove correctly reverted");

        // possessionProven
        console.log("Testing possessionProven - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.paymentEndEpoch, block.number
            )
        );
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        console.log("[OK] possessionProven correctly reverted");

        // nextProvingPeriod
        console.log("Testing nextProvingPeriod - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.paymentEndEpoch, block.number
            )
        );
        pdpServiceWithPayments.nextProvingPeriod(dataSetId, block.number + maxProvingPeriod, 100, "");
        console.log("[OK] nextProvingPeriod correctly reverted");

        console.log("\n=== Test completed successfully! ===");
    }
}

contract SignatureCheckingService is FilecoinWarmStorageService {
    constructor(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        address _usdfcTokenAddress,
        address _filCDNAddress,
        address _serviceProviderRegistryAddress
    )
        FilecoinWarmStorageService(
            _pdpVerifierAddress,
            _paymentsContractAddress,
            _usdfcTokenAddress,
            _filCDNAddress,
            _serviceProviderRegistryAddress
        )
    {}

    function doRecoverSigner(bytes32 messageHash, bytes memory signature) public pure returns (address) {
        return recoverSigner(messageHash, signature);
    }
}

contract FilecoinWarmStorageServiceSignatureTest is Test {
    // Contracts
    SignatureCheckingService public pdpService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public registry;

    // Test accounts with known private keys
    address public payer;
    uint256 public payerPrivateKey;
    address public creator;
    address public wrongSigner;
    uint256 public wrongSignerPrivateKey;
    uint256 public filCDNPrivateKey;
    address public filCDN;

    function setUp() public {
        // Set up test accounts with known private keys
        payerPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        payer = vm.addr(payerPrivateKey);

        wrongSignerPrivateKey = 0x9876543210987654321098765432109876543210987654321098765432109876;
        wrongSigner = vm.addr(wrongSignerPrivateKey);

        filCDNPrivateKey = 0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef;
        filCDN = vm.addr(filCDNPrivateKey);

        creator = address(0xf2);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        registry = ServiceProviderRegistry(address(registryProxy));

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Deploy and initialize the service
        SignatureCheckingService serviceImpl = new SignatureCheckingService(
            address(mockPDPVerifier), address(payments), address(mockUSDFC), filCDN, address(registry)
        );
        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), initData);
        pdpService = SignatureCheckingService(address(serviceProxy));

        // Fund the payer
        mockUSDFC.transfer(payer, 1000 * 10 ** 6); // 1000 USDFC
    }

    // Test the recoverSigner function indirectly through signature verification
    function testRecoverSignerWithValidSignature() public view {
        // Create the message hash that should be signed
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign the message hash with the payer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPrivateKey, messageHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Test that the signature verifies correctly
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, validSignature);
        assertEq(recoveredSigner, payer, "Should recover the correct signer address");
    }

    function testRecoverSignerWithWrongSigner() public view {
        // Create the message hash
        bytes32 messageHash = keccak256(abi.encode(42));

        // Sign with wrong signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongSignerPrivateKey, messageHash);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);

        // Test that the signature recovers the wrong signer (not the expected payer)
        address recoveredSigner = pdpService.doRecoverSigner(messageHash, wrongSignature);
        assertEq(recoveredSigner, wrongSigner, "Should recover the wrong signer address");
        assertTrue(recoveredSigner != payer, "Should not recover the expected payer address");
    }

    function testRecoverSignerInvalidLength() public {
        bytes32 messageHash = keccak256(abi.encode(42));
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes16(0)); // Wrong length (48 bytes instead of 65)

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignatureLength.selector, 65, invalidSignature.length));
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }

    function testRecoverSignerInvalidValue() public {
        bytes32 messageHash = keccak256(abi.encode(42));

        // Create signature with invalid v value
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        uint8 v = 25; // Invalid v value (should be 27 or 28)
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedSignatureV.selector, 25));
        pdpService.doRecoverSigner(messageHash, invalidSignature);
    }
}

// Test contract for upgrade scenarios
contract FilecoinWarmStorageServiceUpgradeTest is Test {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    FilecoinWarmStorageService public warmStorageService;
    MockPDPVerifier public mockPDPVerifier;
    Payments public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public registry;

    address public deployer;
    address public filCDN;

    function setUp() public {
        deployer = address(this);
        filCDN = address(0xf2);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        mockPDPVerifier = new MockPDPVerifier();

        // Deploy actual ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        registry = ServiceProviderRegistry(address(registryProxy));

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Deploy FilecoinWarmStorageService with original initialize (without proving period params)
        // This simulates an existing deployed contract before the upgrade
        FilecoinWarmStorageService warmStorageImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier), address(payments), address(mockUSDFC), filCDN, address(registry)
        );
        bytes memory initData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60) // challengeWindowSize
        );

        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), initData);
        warmStorageService = FilecoinWarmStorageService(address(warmStorageProxy));
    }

    function testConfigureProvingPeriod() public {
        // Test that we can call configureProvingPeriod to set new proving period parameters
        uint64 newMaxProvingPeriod = 120; // 2 hours
        uint256 newChallengeWindowSize = 30;

        // This should work since we're using reinitializer(2)
        warmStorageService.configureProvingPeriod(newMaxProvingPeriod, newChallengeWindowSize);

        // Verify the values were set correctly
        assertEq(warmStorageService.getMaxProvingPeriod(), newMaxProvingPeriod, "Max proving period should be updated");
        assertEq(
            warmStorageService.challengeWindow(), newChallengeWindowSize, "Challenge window size should be updated"
        );
        assertEq(
            warmStorageService.getMaxProvingPeriod(),
            newMaxProvingPeriod,
            "getMaxProvingPeriod should return updated value"
        );
        assertEq(
            warmStorageService.challengeWindow(), newChallengeWindowSize, "challengeWindow should return updated value"
        );
    }

    function testConfigureProvingPeriodWithInvalidParameters() public {
        // Test that configureChallengePeriod validates parameters correctly

        // Test zero max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxProvingPeriodZero.selector));
        warmStorageService.configureProvingPeriod(0, 30);

        // Test zero challenge window size
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 0));
        warmStorageService.configureProvingPeriod(120, 0);

        // Test challenge window size >= max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 120));
        warmStorageService.configureProvingPeriod(120, 120);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 150));
        warmStorageService.configureProvingPeriod(120, 150);
    }

    function testMigrate() public {
        // Test migrate function for versioning
        // Note: This would typically be called during a proxy upgrade via upgradeToAndCall
        // We're testing the function directly here for simplicity

        // Start recording logs
        vm.recordLogs();

        // Simulate calling migrate during upgrade (called by proxy)
        vm.prank(address(warmStorageService));
        warmStorageService.migrate();

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the ContractUpgraded event (reinitializer also emits Initialized event)
        bytes32 expectedTopic = keccak256("ContractUpgraded(string,address)");
        bool foundEvent = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) {
                // Decode and verify the event data
                (string memory version, address implementation) = abi.decode(logs[i].data, (string, address));
                assertEq(version, "0.1.0", "Version should be 0.1.0");
                assertTrue(implementation != address(0), "Implementation address should not be zero");
                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "Should emit ContractUpgraded event");
    }

    function testMigrateOnlyCallableDuringUpgrade() public {
        // Test that migrate can only be called by the contract itself
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlySelf.selector, address(warmStorageService), address(this)));
        warmStorageService.migrate();
    }

    function testMigrateOnlyOnce() public {
        // Test that migrate can only be called once per reinitializer version
        vm.prank(address(warmStorageService));
        warmStorageService.migrate();

        // Second call should fail
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vm.prank(address(warmStorageService));
        warmStorageService.migrate();
    }

    // Event declaration for testing (must match the contract's event)
    event ContractUpgraded(string version, address implementation);
}
