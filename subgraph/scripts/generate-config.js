#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const mustache = require("mustache");
const { loadNetworkConfig } = require("./utils/config-loader");

// Parse command line arguments
const args = process.argv.slice(2);
const shouldGenerateYaml = args.includes("--yaml");

// Get network from command line arguments (excluding flags) or environment variable
const networkArgs = args.filter((arg) => !arg.startsWith("--"));
const network = process.env.NETWORK || networkArgs[0] || "calibration";

const selectedConfig = loadNetworkConfig(network);

if (shouldGenerateYaml) {
  const templatePath = path.join(__dirname, "..", "templates", "subgraph.template.yaml");
  let templateContent;

  try {
    templateContent = fs.readFileSync(templatePath, "utf8");
  } catch (error) {
    console.error(`Error: Failed to read subgraph template at: ${templatePath}`);
    console.error(`Template Error: ${error.message}`);
    process.exit(1);
  }

  const yamlContent = mustache.render(templateContent, selectedConfig);

  const outputPath = path.join(__dirname, "..", "subgraph.yaml");

  try {
    fs.writeFileSync(outputPath, yamlContent);
    console.log(`✅ Generated subgraph.yaml for ${network} network at: ${outputPath}`);
    console.log(`   Source: service_contracts/deployments.json`);
  } catch (error) {
    console.error(`Error: Failed to write subgraph.yaml to: ${outputPath}`);
    console.error(`Write Error: ${error.message}`);
    process.exit(1);
  }
} else {
  console.log(JSON.stringify(selectedConfig, null, 2));
}
