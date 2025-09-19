const fs = require("fs");
const path = require("path");

/**
 * Loads and validates network configuration from config/network.json
 * @param {string} network - The network name to load
 * @returns {Object} The network configuration object
 */
function loadNetworkConfig(network = "calibration") {
  const configPath = path.join(__dirname, "..", "..", "config", "network.json");
  let networkConfig;

  try {
    const configContent = fs.readFileSync(configPath, "utf8");
    networkConfig = JSON.parse(configContent);
  } catch (error) {
    if (error.code === "ENOENT") {
      console.error(`Error: Configuration file not found at: ${configPath}`);
      console.error("Please ensure config/network.json exists in your project.");
      process.exit(1);
    }
    if (error instanceof SyntaxError) {
      console.error(`Error: Invalid JSON in configuration file: ${configPath}`);
      console.error("Please check that config/network.json contains valid JSON.");
      console.error(`JSON Error: ${error.message}`);
    } else {
      console.error(`Error reading configuration file: ${configPath}`);
      console.error(`File Error: ${error.message}`);
    }
    process.exit(1);
  }

  if (!networkConfig.networks) {
    console.error("Error: Invalid configuration structure. Missing 'networks' object in config/network.json");
    console.error('Expected structure: { "networks": { "calibration": {...}, "mainnet": {...} } }');
    process.exit(1);
  }

  if (!networkConfig.networks[network]) {
    console.error(`Error: Network '${network}' not found in config/network.json`);
    console.error(`Available networks: ${Object.keys(networkConfig.networks).join(", ")}`);
    process.exit(1);
  }

  return networkConfig.networks[network];
}

module.exports = { loadNetworkConfig };
