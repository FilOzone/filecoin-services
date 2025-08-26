// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Payments} from "@fws-payments/Payments.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Errors} from "../src/Errors.sol";

// Simple mock for testing
contract MockERC20 is IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor() {
        _mint(msg.sender, 1000000 * 10 ** 6);
    }

    function name() public pure override returns (string memory) {
        return "USDFC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDFC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        _allowances[sender][msg.sender] -= amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function _mint(address account, uint256 amount) internal {
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }
}

contract MockPDPVerifier {
    function createDataSet(address listenerAddr, bytes calldata extraData) public returns (uint256) {
        FilecoinWarmStorageService(listenerAddr).dataSetCreated(1, msg.sender, extraData);
        return 1;
    }
}

contract ProviderValidationTest is Test {
    FilecoinWarmStorageService public warmStorage;
    ServiceProviderRegistry public registry;
    MockPDPVerifier public pdpVerifier;
    Payments public payments;
    MockERC20 public usdfc;

    address public owner;
    address public provider1;
    address public provider2;
    address public client;
    address public filCDN;

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        uint8(27)
    );

    function setUp() public {
        owner = address(this);
        provider1 = address(0x1);
        provider2 = address(0x2);
        client = address(0x3);
        filCDN = address(0x4);

        // Fund accounts
        vm.deal(provider1, 10 ether);
        vm.deal(provider2, 10 ether);

        // Deploy contracts
        usdfc = new MockERC20();
        pdpVerifier = new MockPDPVerifier();

        // Deploy ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        registry = ServiceProviderRegistry(address(registryProxy));

        // Deploy Payments
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));

        // Deploy FilecoinWarmStorageService
        FilecoinWarmStorageService warmStorageImpl = new FilecoinWarmStorageService(
            address(pdpVerifier), address(payments), address(usdfc), filCDN, address(registry)
        );
        bytes memory warmStorageInitData =
            abi.encodeWithSelector(FilecoinWarmStorageService.initialize.selector, uint64(2880), uint256(60));
        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), warmStorageInitData);
        warmStorage = FilecoinWarmStorageService(address(warmStorageProxy));

        // Transfer tokens to client
        usdfc.transfer(client, 10000 * 10 ** 6);
    }

    function testProviderNotRegistered() public {
        // Try to create dataset with unregistered provider
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotRegistered.selector, provider1));
        pdpVerifier.createDataSet(address(warmStorage), extraData);
    }

    function testProviderRegisteredButNotApproved() public {
        // Register provider1 in registry
        vm.prank(provider1);
        registry.registerProvider{value: 5 ether}(
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-West",
                    paymentTokenAddress: address(0) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Try to create dataset without approval
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotApproved.selector, provider1, 1));
        pdpVerifier.createDataSet(address(warmStorage), extraData);
    }

    function testProviderApprovedCanCreateDataset() public {
        // Register provider1 in registry
        vm.prank(provider1);
        registry.registerProvider{value: 5 ether}(
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-West",
                    paymentTokenAddress: address(0) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Approve provider1
        warmStorage.addApprovedProvider(1);

        // Approve USDFC spending, deposit and set operator
        vm.startPrank(client);
        usdfc.approve(address(payments), 10000 * 10 ** 6);
        payments.deposit(address(usdfc), client, 10000 * 10 ** 6); // Deposit funds
        payments.setOperatorApproval(
            address(usdfc), // token
            address(warmStorage), // operator
            true, // approved
            10000 * 10 ** 6, // rateAllowance
            10000 * 10 ** 6, // lockupAllowance
            10000 * 10 ** 6 // allowance
        );
        vm.stopPrank();

        // Create dataset should succeed
        string[] memory metadataKeys = new string[](1);
        string[] memory metadataValues = new string[](1);
        metadataKeys[0] = "description";
        metadataValues[0] = "Test dataset";
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        uint256 dataSetId = pdpVerifier.createDataSet(address(warmStorage), extraData);
        assertEq(dataSetId, 1, "Dataset should be created");
    }

    function testAddAndRemoveApprovedProvider() public {
        // Test adding provider
        warmStorage.addApprovedProvider(1);
        assertTrue(warmStorage.isProviderApproved(1), "Provider 1 should be approved");

        // Test adding already approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 1));
        warmStorage.addApprovedProvider(1);

        // Test removing provider
        warmStorage.removeApprovedProvider(1);
        assertFalse(warmStorage.isProviderApproved(1), "Provider 1 should not be approved");

        // Test removing non-approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 2));
        warmStorage.removeApprovedProvider(2);

        // Test removing already removed provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 1));
        warmStorage.removeApprovedProvider(1);
    }

    function testOnlyOwnerCanManageApprovedProviders() public {
        // Non-owner tries to add provider
        vm.prank(provider1);
        vm.expectRevert();
        warmStorage.addApprovedProvider(1);

        // Non-owner tries to remove provider
        warmStorage.addApprovedProvider(1);
        vm.prank(provider1);
        vm.expectRevert();
        warmStorage.removeApprovedProvider(1);
    }

    function testAddApprovedProviderAlreadyApproved() public {
        // First add should succeed
        warmStorage.addApprovedProvider(5);
        assertTrue(warmStorage.isProviderApproved(5), "Provider 5 should be approved");

        // Second add should revert with ProviderAlreadyApproved error
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 5));
        warmStorage.addApprovedProvider(5);
    }

    function testRemoveApprovedProviderNotInList() public {
        // Trying to remove a provider that was never approved should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 10));
        warmStorage.removeApprovedProvider(10);

        // Add and then remove a provider
        warmStorage.addApprovedProvider(6);
        warmStorage.removeApprovedProvider(6);

        // Trying to remove the same provider again should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 6));
        warmStorage.removeApprovedProvider(6);
    }
}
