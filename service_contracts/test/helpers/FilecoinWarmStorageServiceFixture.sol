// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Cids} from "@pdp/Cids.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceFilBeamModule} from "../../src/modules/FilecoinWarmStorageServiceFilBeamModule.sol";
import {FilecoinWarmStorageServiceStateView} from "../../src/FilecoinWarmStorageServiceStateView.sol";
import {FilecoinWarmStorageServiceStateLibrary} from "../../src/lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {MockERC20, MockPDPVerifier} from "../mocks/SharedMocks.sol";
import {PDPOffering} from "../PDPOffering.sol";
import {ServiceProviderRegistryStorage} from "../../src/ServiceProviderRegistryStorage.sol";
import {ServiceProviderRegistry} from "../../src/ServiceProviderRegistry.sol";

contract FilecoinWarmStorageServiceHarness is FilecoinWarmStorageService {
    constructor(
        address pdpVerifier,
        address payments,
        MockERC20 usdfc,
        address filBeamBeneficiary,
        ServiceProviderRegistry providerRegistry,
        SessionKeyRegistry sessionKeyRegistry,
        uint64 reinitializerVersion
    )
        FilecoinWarmStorageService(
            pdpVerifier, payments, usdfc, filBeamBeneficiary, providerRegistry, sessionKeyRegistry, reinitializerVersion
        )
    {}

    function seedLegacyPieceMetadata(
        uint256 dataSetId,
        uint256 pieceId,
        string[] calldata keys,
        string[] calldata values
    ) external {
        for (uint256 i = 0; i < keys.length; i++) {
            dataSetPieceMetadata[dataSetId][pieceId][keys[i]] = values[i];
            dataSetPieceMetadataKeys[dataSetId][pieceId].push(keys[i]);
        }
    }

    function legacyPieceMetadataKeysLength(uint256 dataSetId, uint256 pieceId) external view returns (uint256) {
        return dataSetPieceMetadataKeys[dataSetId][pieceId].length;
    }

    function legacyPieceMetadataValue(uint256 dataSetId, uint256 pieceId, string calldata key)
        external
        view
        returns (string memory)
    {
        return dataSetPieceMetadata[dataSetId][pieceId][key];
    }
}

contract FilecoinWarmStorageServiceFilBeamHarness is
    FilecoinWarmStorageServiceHarness,
    FilecoinWarmStorageServiceFilBeamModule
{
    constructor(
        address pdpVerifier,
        address payments,
        MockERC20 usdfc,
        address filBeamBeneficiary,
        ServiceProviderRegistry providerRegistry,
        SessionKeyRegistry sessionKeyRegistry,
        uint64 reinitializerVersion
    )
        FilecoinWarmStorageServiceHarness(
            pdpVerifier, payments, usdfc, filBeamBeneficiary, providerRegistry, sessionKeyRegistry, reinitializerVersion
        )
    {}
}

abstract contract FilecoinWarmStorageServiceFixture is MockFVMTest {
    using SafeERC20 for MockERC20;
    using PDPOffering for PDPOffering.Schema;
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;
    // Testing Constants

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    // Contracts
    FilecoinWarmStorageService public pdpServiceWithPayments;
    FilecoinWarmStorageServiceStateView public viewContract;
    MockPDPVerifier public mockPDPVerifier;
    FilecoinPayV1 public payments;
    MockERC20 public mockUSDFC;
    ServiceProviderRegistry public serviceProviderRegistry;
    SessionKeyRegistry public sessionKeyRegistry = new SessionKeyRegistry();

    // Test accounts
    address public deployer;
    address public client;
    address public serviceProvider;
    address public filBeamController;
    address public filBeamBeneficiary;
    address public session;

    address public sp1;
    address public sp2;
    address public sp3;

    address public sessionKey1;
    address public sessionKey2;

    // Test parameters
    bytes public extraData;

    // Metadata size and count limits
    uint256 internal constant MAX_KEY_LENGTH = 32;
    uint256 internal constant MAX_VALUE_LENGTH = 96;
    uint256 internal constant MAX_KEYS_PER_DATASET = 10;
    uint256 internal constant MAX_KEYS_PER_PIECE = 3;

    bytes32 internal constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)"
        "MetadataEntry(string key,string value)"
    );
    bytes32 internal constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );
    bytes32 internal constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");
    bytes32 internal constant TERMINATE_SERVICE_TYPEHASH = keccak256("TerminateService(uint256 dataSetId)");

    // Expected lockup amounts for CDN rails
    uint256 defaultCDNLockup;
    uint256 defaultCacheMissLockup;
    uint256 defaultTotalCDNLockup;

    // Structs
    struct PieceMetadataSetup {
        uint256 dataSetId;
        uint256 pieceId;
        Cids.Cid[] pieceData;
        bytes extraData;
    }

    function setUp() public virtual override {
        super.setUp();
        // Setup test accounts
        deployer = address(this);
        client = address(0xf1);
        serviceProvider = address(0xf2);
        filBeamController = address(0xf3);
        filBeamBeneficiary = address(0xf4);

        // Additional accounts for serviceProviderRegistry tests
        sp1 = address(0xf5);
        sp2 = address(0xf6);
        sp3 = address(0xf7);

        // Session keys
        sessionKey1 = address(0xa1);
        sessionKey2 = address(0xa2);

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
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry(1);
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));

        PDPOffering.Schema memory pdpData = PDPOffering.Schema({
            serviceURL: "https://provider.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-Central",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });
        (string[] memory keys, bytes[] memory values) = pdpData.toCapabilities();

        // Register service providers in the serviceProviderRegistry
        vm.prank(serviceProvider);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            serviceProvider, // payee
            "Service Provider",
            "Service Provider Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = bytes("https://sp1.com");
        vm.prank(sp1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp1, // payee
            "SP1",
            "Storage Provider 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = bytes("https://sp2.com");
        vm.prank(sp2);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp2, // payee
            "SP2",
            "Storage Provider 2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = bytes("https://sp3.com");
        vm.prank(sp3);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp3, // payee
            "SP3",
            "Storage Provider 3",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Deploy FilecoinPayV1 contract (no longer upgradeable)
        payments = new FilecoinPayV1();

        // Transfer tokens to client for payment
        mockUSDFC.safeTransfer(client, 10000 * 10 ** mockUSDFC.decimals());

        // Initialize expected lockup amounts
        defaultCDNLockup = (7 * 10 ** mockUSDFC.decimals()) / 10; // 0.7 USDFC
        defaultCacheMissLockup = (3 * 10 ** mockUSDFC.decimals()) / 10; // 0.3 USDFC
        defaultTotalCDNLockup = defaultCacheMissLockup + defaultCDNLockup;

        // Deploy FilecoinWarmStorageService with proxy
        FilecoinWarmStorageService pdpServiceImpl = _deployServiceImplementation();
        bytes memory initializeData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880), // maxProvingPeriod
            uint256(60), // challengeWindowSize
            filBeamController // filBeamControllerAddress
        );

        MyERC1967Proxy pdpServiceProxy = new MyERC1967Proxy(address(pdpServiceImpl), initializeData);
        pdpServiceWithPayments = FilecoinWarmStorageService(address(pdpServiceProxy));

        viewContract = new FilecoinWarmStorageServiceStateView(pdpServiceWithPayments);
        pdpServiceWithPayments.setViewContract(address(viewContract));
    }

    function _seedLegacyPieceMetadata(uint256 dataSetId, uint256 pieceId, string[] memory keys, string[] memory values)
        internal
    {
        FilecoinWarmStorageServiceHarness(address(pdpServiceWithPayments))
            .seedLegacyPieceMetadata(dataSetId, pieceId, keys, values);
    }

    function _legacyPieceMetadataKeysLength(uint256 dataSetId, uint256 pieceId) internal view returns (uint256) {
        return FilecoinWarmStorageServiceHarness(address(pdpServiceWithPayments))
            .legacyPieceMetadataKeysLength(dataSetId, pieceId);
    }

    function _legacyPieceMetadataValue(uint256 dataSetId, uint256 pieceId, string memory key)
        internal
        view
        returns (string memory)
    {
        return FilecoinWarmStorageServiceHarness(address(pdpServiceWithPayments))
            .legacyPieceMetadataValue(dataSetId, pieceId, key);
    }

    function makeSignaturePass(address signer) public {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""), // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function _generateKey(uint256 index) public pure returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked("base_salt", index));

        // Convert hash to hex string
        string memory hexStr = Strings.toHexString(uint256(hash), 32); // 0x + 64 chars

        // Remove the "0x" prefix and take only first 32 characters to make exactly 32 bytes
        bytes memory keyBytes = bytes(hexStr);
        bytes memory result = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            result[i] = keyBytes[i + 2]; // skip '0x'
        }

        return string(result); // exactly 32-byte unique string
    }

    function _deployServiceImplementation() internal virtual returns (FilecoinWarmStorageService) {
        return new FilecoinWarmStorageServiceHarness(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
    }

    uint256 nextClientDataSetId = 0;

    function _getSingleMetadataKV(string memory key, string memory value)
        internal
        pure
        returns (string[] memory, string[] memory)
    {
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = key;
        values[0] = value;
        return (keys, values);
    }

    function prepareDataSetForClient(
        address, /*provider*/
        address clientAddress,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) internal returns (bytes memory) {
        // Prepare extra data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
            metadataKeys: metadataKeys,
            clientDataSetId: nextClientDataSetId++,
            metadataValues: metadataValues,
            payer: clientAddress,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval if not already done
        vm.startPrank(clientAddress);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 100e18);
        payments.deposit(mockUSDFC, clientAddress, 100e18);
        vm.stopPrank();

        // Create data set as approved provider
        makeSignaturePass(clientAddress);

        return encodedData;
    }

    function createDataSetForClient(
        address provider,
        address clientAddress,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) internal returns (uint256) {
        bytes memory encodedData = prepareDataSetForClient(provider, clientAddress, metadataKeys, metadataValues);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
    }
}
