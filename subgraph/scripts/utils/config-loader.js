const fs = require("fs");
const path = require("path");

// Network name to chain ID mapping
const NETWORK_CHAIN_IDS = {
  mainnet: "314",
  calibration: "314159",
};

// Network name to subgraph network name mapping
const NETWORK_NAMES = {
  mainnet: "filecoin",
  calibration: "filecoin-testnet",
};

// Mapping from deployments.json keys to template keys
const ADDRESS_MAPPING = {
  PDP_VERIFIER_PROXY_ADDRESS: "PDPVerifier",
  SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS: "ServiceProviderRegistry",
  FWSS_PROXY_ADDRESS: "FilecoinWarmStorageService",
  FILECOIN_PAY_ADDRESS: "USDFCToken",
};

// Default start blocks for each network (can be overridden via environment or config)
// These represent the approximate deployment blocks for the contracts
const DEFAULT_START_BLOCKS = {
  mainnet: {
    PDPVerifier: 1000000,
    ServiceProviderRegistry: 1000000,
    FilecoinWarmStorageService: 1000000,
    USDFCToken: 1000000,
  },
  calibration: {
    PDPVerifier: 2988297,
    ServiceProviderRegistry: 2988311,
    FilecoinWarmStorageService: 2988329,
    USDFCToken: 2988000,
  },
};

/**
 * Loads deployment addresses from service_contracts/deployments.json
 * @returns {Object} The parsed deployments object
 */
function loadDeployments() {
  const deploymentsPath = path.join(
    __dirname,
    "..",
    "..",
    "..",
    "service_contracts",
    "deployments.json"
  );

  try {
    const content = fs.readFileSync(deploymentsPath, "utf8");
    return JSON.parse(content);
  } catch (error) {
    if (error.code === "ENOENT") {
      console.error(`Error: Deployments file not found at: ${deploymentsPath}`);
      console.error(
        "Please ensure service_contracts/deployments.json exists."
      );
      process.exit(1);
    }
    if (error instanceof SyntaxError) {
      console.error(
        `Error: Invalid JSON in deployments file: ${deploymentsPath}`
      );
      console.error(`JSON Error: ${error.message}`);
    } else {
      console.error(`Error reading deployments file: ${deploymentsPath}`);
      console.error(`File Error: ${error.message}`);
    }
    process.exit(1);
  }
}

/**
 * Loads optional start block overrides from config/start-blocks.json
 * @param {string} network - The network name
 * @returns {Object|null} The start blocks object or null if not found
 */
function loadStartBlockOverrides(network) {
  const overridesPath = path.join(
    __dirname,
    "..",
    "..",
    "config",
    "start-blocks.json"
  );

  try {
    const content = fs.readFileSync(overridesPath, "utf8");
    const overrides = JSON.parse(content);
    return overrides[network] || null;
  } catch {
    // Start block overrides are optional
    return null;
  }
}

/**
 * Loads and validates network configuration from service_contracts/deployments.json
 * @param {string} network - The network name to load ("mainnet" or "calibration")
 * @returns {Object} The network configuration object formatted for templates
 */
function loadNetworkConfig(network = "calibration") {
  const chainId = NETWORK_CHAIN_IDS[network];

  if (!chainId) {
    console.error(`Error: Unknown network '${network}'`);
    console.error(
      `Available networks: ${Object.keys(NETWORK_CHAIN_IDS).join(", ")}`
    );
    process.exit(1);
  }

  const deployments = loadDeployments();
  const networkDeployments = deployments[chainId];

  if (!networkDeployments) {
    console.error(
      `Error: No deployments found for chain ID ${chainId} (network: ${network})`
    );
    console.error(`Available chain IDs: ${Object.keys(deployments).join(", ")}`);
    process.exit(1);
  }

  // Load start block overrides (optional)
  const startBlockOverrides = loadStartBlockOverrides(network);
  const defaultStartBlocks = DEFAULT_START_BLOCKS[network] || {};

  // Build the configuration object expected by templates
  const config = {
    name: NETWORK_NAMES[network],
  };

  // Map deployment addresses to template format
  for (const [deploymentKey, templateKey] of Object.entries(ADDRESS_MAPPING)) {
    const address = networkDeployments[deploymentKey];

    if (!address) {
      console.error(
        `Error: Missing '${deploymentKey}' in deployments.json for chain ID ${chainId}`
      );
      process.exit(1);
    }

    // Get start block from overrides, defaults, or fallback
    const startBlock =
      startBlockOverrides?.[templateKey] ||
      defaultStartBlocks[templateKey] ||
      0;

    config[templateKey] = {
      address: address,
      startBlock: startBlock,
    };
  }

  return config;
}

/**
 * Gets the path to an ABI file
 * @param {string} contractName - The contract name (e.g., "PDPVerifier")
 * @returns {string} The absolute path to the ABI file
 */
function getAbiPath(contractName) {
  return path.join(
    __dirname,
    "..",
    "..",
    "..",
    "service_contracts",
    "abi",
    `${contractName}.abi.json`
  );
}

/**
 * Loads an ABI from service_contracts/abi/
 * @param {string} contractName - The contract name (e.g., "PDPVerifier")
 * @returns {Array} The parsed ABI array
 */
function loadAbi(contractName) {
  const abiPath = getAbiPath(contractName);

  try {
    const content = fs.readFileSync(abiPath, "utf8");
    return JSON.parse(content);
  } catch (error) {
    if (error.code === "ENOENT") {
      console.error(`Error: ABI file not found at: ${abiPath}`);
      console.error(
        `Please ensure service_contracts/abi/${contractName}.abi.json exists.`
      );
      process.exit(1);
    }
    if (error instanceof SyntaxError) {
      console.error(`Error: Invalid JSON in ABI file: ${abiPath}`);
      console.error(`JSON Error: ${error.message}`);
    } else {
      console.error(`Error reading ABI file: ${abiPath}`);
      console.error(`File Error: ${error.message}`);
    }
    process.exit(1);
  }
}

module.exports = { loadNetworkConfig, loadDeployments, loadAbi, getAbiPath };
