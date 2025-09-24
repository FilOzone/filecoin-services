#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const mustache = require("mustache");
const { loadNetworkConfig } = require("./utils/config-loader");

// Parse command line arguments
const args = process.argv.slice(2);

// Get network from command line arguments (excluding flags) or environment variable
const networkArgs = args.filter((arg) => !arg.startsWith("--"));
const network = process.env.NETWORK || networkArgs[0] || "calibration";

const selectedConfig = loadNetworkConfig(network);

const requiredContracts = ["PDPVerifier", "ServiceProviderRegistry", "FilecoinWarmStorageService", "USDFCToken"];
for (const contract of requiredContracts) {
  if (!selectedConfig[contract] || !selectedConfig[contract].address) {
    console.error(`Error: Missing or invalid '${contract}' configuration for network '${network}'`);
    console.error(`Each contract must have an 'address' field in config/network.json`);
    process.exit(1);
  }
}

const templatePath = path.join(__dirname, "..", "templates", "constants.template.ts");
let templateContent;

try {
  templateContent = fs.readFileSync(templatePath, "utf8");
} catch (error) {
  console.error(`Error: Failed to read constants template at: ${templatePath}`);
  console.error(`Template Error: ${error.message}`);
  process.exit(1);
}

const templateData = {
  network: network,
  timestamp: new Date().toISOString(),
  ...selectedConfig,
};

const constantsContent = mustache.render(templateContent, templateData);

const generatedDir = path.join(__dirname, "..", "src", "generated");
const outputPath = path.join(generatedDir, "constants.ts");

try {
  fs.mkdirSync(generatedDir, { recursive: true });

  fs.writeFileSync(outputPath, constantsContent);
  console.log(`✅ Generated constants for ${network} network at: ${outputPath}`);
} catch (error) {
  console.error(`Error: Failed to write constants file to: ${outputPath}`);
  console.error(`Write Error: ${error.message}`);
  console.error("Please check directory permissions and available disk space.");
  process.exit(1);
}
