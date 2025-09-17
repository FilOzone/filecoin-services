#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

// Get network from command line argument or environment variable
const network = process.argv[2] || process.env.NETWORK || "calibration";

// Read the network configuration
const configPath = path.join(__dirname, "..", "config", "network.json");
const networkConfig = JSON.parse(fs.readFileSync(configPath, "utf8"));

// Check if the network exists in the configuration
if (!networkConfig.networks[network]) {
  console.error(`Error: Network '${network}' not found in config/network.json`);
  console.error(`Available networks: ${Object.keys(networkConfig.networks).join(", ")}`);
  process.exit(1);
}

// Output the specific network configuration
const selectedConfig = networkConfig.networks[network];
console.log(JSON.stringify(selectedConfig, null, 2));
