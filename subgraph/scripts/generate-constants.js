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

const selectedConfig = networkConfig.networks[network];

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

// Ensure the generated directory exists
const generatedDir = path.join(__dirname, "..", "src", "generated");
if (!fs.existsSync(generatedDir)) {
  fs.mkdirSync(generatedDir, { recursive: true });
}

// Write the constants file
const outputPath = path.join(generatedDir, "constants.ts");
fs.writeFileSync(outputPath, constantsContent);

console.log(`✅ Generated constants for ${network} network at: ${outputPath}`);
