#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

// Get network from command line argument or environment variable
const network = process.argv[2] || process.env.NETWORK || "calibration";

// Read the network configuration
const configPath = path.join(__dirname, "..", "config", "network.json");
let networkConfig;

try {
  if (!fs.existsSync(configPath)) {
    console.error(`Error: Configuration file not found at: ${configPath}`);
    console.error("Please ensure config/network.json exists in your project.");
    process.exit(1);
  }

  const configContent = fs.readFileSync(configPath, "utf8");
  networkConfig = JSON.parse(configContent);
} catch (error) {
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

// Validate configuration structure
if (!networkConfig.networks) {
  console.error("Error: Invalid configuration structure. Missing 'networks' object in config/network.json");
  console.error("Expected structure: { \"networks\": { \"calibration\": {...}, \"mainnet\": {...} } }");
  process.exit(1);
}

// Check if the network exists in the configuration
if (!networkConfig.networks[network]) {
  console.error(`Error: Network '${network}' not found in config/network.json`);
  console.error(`Available networks: ${Object.keys(networkConfig.networks).join(", ")}`);
  process.exit(1);
}

// Output the specific network configuration
const selectedConfig = networkConfig.networks[network];
console.log(JSON.stringify(selectedConfig, null, 2));
