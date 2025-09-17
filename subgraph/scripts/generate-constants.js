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

const selectedConfig = networkConfig.networks[network];

// Validate required contract configurations
const requiredContracts = ["PDPVerifier", "ServiceProviderRegistry", "FilecoinWarmStorageService", "USDFCToken"];
for (const contract of requiredContracts) {
  if (!selectedConfig[contract] || !selectedConfig[contract].address) {
    console.error(`Error: Missing or invalid '${contract}' configuration for network '${network}'`);
    console.error(`Each contract must have an 'address' field in config/network.json`);
    process.exit(1);
  }
}

// Generate the TypeScript constants file
const constantsContent = `// This file is auto-generated. Do not edit manually.
// Generated from config/network.json for network: ${network}
// Last generated: ${new Date().toISOString()}

import { Address, Bytes } from "@graphprotocol/graph-ts";

export class ContractAddresses {
  static readonly PDPVerifier: Address = Address.fromBytes(
    Bytes.fromHexString("${selectedConfig.PDPVerifier.address}"),
  );
  static readonly ServiceProviderRegistry: Address = Address.fromBytes(
    Bytes.fromHexString("${selectedConfig.ServiceProviderRegistry.address}"),
  );
  static readonly FilecoinWarmStorageService: Address = Address.fromBytes(
    Bytes.fromHexString("${selectedConfig.FilecoinWarmStorageService.address}"),
  );
  static readonly USDFCToken: Address = Address.fromBytes(
    Bytes.fromHexString("${selectedConfig.USDFCToken.address}"),
  );
}
`;

// Ensure the generated directory exists and write the constants file
const generatedDir = path.join(__dirname, "..", "src", "generated");
const outputPath = path.join(generatedDir, "constants.ts");

try {
  if (!fs.existsSync(generatedDir)) {
    fs.mkdirSync(generatedDir, { recursive: true });
  }

  fs.writeFileSync(outputPath, constantsContent);
  console.log(`✅ Generated constants for ${network} network at: ${outputPath}`);
} catch (error) {
  console.error(`Error: Failed to write constants file to: ${outputPath}`);
  console.error(`Write Error: ${error.message}`);
  console.error("Please check directory permissions and available disk space.");
  process.exit(1);
}
