# Filecoin Services Subgraph - Multi-Network Deployment

This guide details the steps required to deploy the subgraph to multiple Filecoin networks (testnet and mainnet) using mustache templating for network-specific configurations.

## Prerequisites

Before you begin, ensure you have the following installed and set up:

1.  **Node.js and npm/yarn:** The subgraph development and client rely on Node.js. Download and install it from [nodejs.org](https://nodejs.org/). npm is included, or you can install yarn ([yarnpkg.com](https://classic.yarnpkg.com/en/docs/install)). **Ensure you have Node.js version 20.18.1 or higher.**
2.  **Graph CLI:** This command-line tool is essential for interacting with subgraphs (code generation, building). Install it globally:
    ```bash
    npm install -g @graphprotocol/graph-cli
    # or
    yarn global add @graphprotocol/graph-cli
    ```
    Refer to the [Graph CLI documentation](https://github.com/graphprotocol/graph-tooling/tree/main/packages/cli) for more details.
3.  **Goldsky Account:** You need an account on Goldsky to host your subgraph. Sign up at [goldsky.com](https://goldsky.com/).
4.  **Goldsky CLI:** This tool allows you to deploy subgraphs to the Goldsky platform. Follow the installation instructions in the [Goldsky Documentation](https://docs.goldsky.com/introduction).

## Multi-Network Configuration

This subgraph supports deployment to multiple Filecoin networks using mustache templating. The configuration is managed through:

- **`config/network.json`**: Contains network-specific contract addresses and start blocks
- **`templates/subgraph.template.yaml`**: Template file with mustache variables for subgraph configuration
- **`templates/constants.template.ts`**: Template file with mustache variables for TypeScript constants
- **`scripts/generate-config.js`**: Script to extract network-specific configuration
- **`scripts/generate-constants.js`**: Script to generate TypeScript constants from template

### Available Networks

- **Calibration**: Calibration network configuration (ready to use)
- **Mainnet**: Filecoin mainnet configuration (requires contract addresses)

### Quick Start Commands

For **Calibration**:

```bash
# Build for calibration
npm run build:calibration

# Deploy to calibration
goldsky subgraph deploy <your-subgraph-name>/<version>
```

For **Mainnet**:

```bash
# Build for mainnet
npm run build:mainnet

# Deploy to mainnet
goldsky subgraph deploy <your-subgraph-name>/<version>
```

### Available Scripts

The following npm scripts are available for multi-network deployment:

**Network-specific builds:**

- `npm run build:calibration` - Build for calibration network
- `npm run build:mainnet` - Build for mainnet

**Template generation:**

- `npm run generate:yaml:calibration` - Generate subgraph.yaml for calibration
- `npm run generate:yaml:mainnet` - Generate subgraph.yaml for mainnet

**Constants generation:**

- `npm run generate:constants:calibration` - Generate contract addresses for calibration
- `npm run generate:constants:mainnet` - Generate contract addresses for mainnet

**Environment variable approach:**

```bash
# Set network via environment variable (defaults to calibration)
NETWORK=mainnet npm run precodegen
```

**Cross-Platform Compatibility**: All scripts are designed to work on Windows, macOS, and Linux without requiring shell-specific features like pipes or redirects.

## Automated Contract Address Generation

One of the key features of this setup is **automated contract address generation**. Instead of manually updating hardcoded addresses in your TypeScript files, the system automatically generates them from your network configuration.

### How It Works

1. **Configuration Source**: Contract addresses are defined in `config/network.json`
2. **Template Files**: Mustache templates in `templates/` define structure for generated files
3. **Generation Scripts**:
   - `scripts/generate-config.js` extracts network config and optionally generates subgraph.yaml (cross-platform)
   - `scripts/generate-constants.js` uses `templates/constants.template.ts` to generate TypeScript constants
4. **Generated Files**: Creates `src/generated/constants.ts` and `subgraph.yaml` with network-specific data
5. **Import**: Your code imports from the generated file via `src/utils/constants.ts`

### Generated Constants Structure

The generated `src/generated/constants.ts` includes:

```typescript
export class ContractAddresses {
  static readonly PDPVerifier: Address = Address.fromBytes(/*...*/);
  static readonly ServiceProviderRegistry: Address = Address.fromBytes(/*...*/);
  static readonly FilecoinWarmStorageService: Address = Address.fromBytes(/*...*/);
  static readonly USDFCToken: Address = Address.fromBytes(/*...*/);
}
```

### Usage in Code

```typescript
import { ContractAddresses } from "./constants";

// Use network-specific addresses
const pdpContract = PDPVerifier.bind(ContractAddresses.PDPVerifier);
```

## Deploying the Subgraph

Follow these steps to build and deploy the subgraph:

1.  **Navigate to Subgraph Directory:**
    Open your terminal and change to the `subgraph` directory within the project:

    ```bash
    cd path/to/pdp-explorer/subgraph
    ```

2.  **Install Dependencies:**
    Install the necessary node modules:

    ```bash
    npm install
    # or
    yarn install
    # or
    npm install
    ```

3.  **Authenticate with Goldsky:**
    Log in to your Goldsky account using the CLI. Go to settings section of your Goldsky dashboard to get your API key.

    ```bash
    goldsky login
    ```

4.  **Build the Subgraph:**
    Compile your subgraph code into WebAssembly (WASM) for the selected network ( calibration or mainnet).

    ```bash
    npm run build:calibration
    # or
    npm run build:mainnet
    ```

5.  **Deploy to Goldsky:**
    Use the Goldsky CLI to deploy your built subgraph.

    ```bash
    goldsky subgraph deploy <your-subgraph-name>/<version> --path ./
    ```

    - Replace `<your-subgraph-name>` with the desired name for your subgraph deployment on Goldsky (e.g., `fwss-subgraph`). You can create/manage this name in your Goldsky dashboard.
    - Replace `<version>` with a version identifier (e.g., `v0.0.1`).
    - You can manage your deployments and find your subgraph details in the [Goldsky Dashboard](https://app.goldsky.com/). The deployment command will output the GraphQL endpoint URL for your subgraph upon successful completion. **Copy this URL**, as you will need it for the client.

6.  **Tag the Subgraph (Optional):**
    Tag the subgraph you deployed in step 5.

    ```bash
    goldsky subgraph tag create <your-subgraph-name>/<version> --tag <tag-name>
    ```

    - Replace `<tag-name>` with a tag name (e.g., `mainnet`).

    Remove the tag when you want to deploy a new version of the subgraph.

    ```bash
    goldsky subgraph tag delete <your-subgraph-name>/<version> --tag <tag-name>
    ```

## Modifying and Redeploying the Subgraph

If you need to make changes to the subgraph's logic, schema, or configuration, follow these general steps:

1.  **Modify Code:** Edit the relevant files:

    - `config/network.json`: To update contract addresses.
    - `schemas/schema.*.graphql`: To change the data structure and entities being stored.
    - `templates/subgraph.template.yaml`: To update contract addresses, ABIs, start blocks, or event handlers.
    - `src/*.ts`: To alter the logic that processes blockchain events and maps them to the defined schema entities.
    - `src/utils/*.ts`: If modifying shared utility functions or constants.

2.  **Rebuild:** Compile the updated subgraph code using `npm run build:<network>`:

    ```bash
    npm run build:calibration
    # or
    npm run build:mainnet
    ```

3.  **Redeploy:** Deploy the new version to Goldsky. It's good practice to increment the version number:
    ```bash
    goldsky subgraph deploy <your-subgraph-name>/<new-version> --path ./
    ```
    Replace `<new-version>` (e.g., `v0.0.2`).

**Development Resources:**

- **AssemblyScript:** Subgraph mappings are written in AssemblyScript, a subset of TypeScript that compiles to Wasm. Learn more at [https://www.assemblyscript.org/](https://www.assemblyscript.org/).
- **The Graph Documentation:** The official documentation covers subgraph development in detail: [https://thegraph.com/docs/en/subgraphs/developing/creating/starting-your-subgraph/](https://thegraph.com/docs/en/subgraphs/developing/creating/starting-your-subgraph/).

## Further Information

- **Warm Storage Subgraph Api Documentation** [graphql](./API.md)
- **Graph Protocol Documentation:** [https://thegraph.com/docs/en/](https://thegraph.com/docs/en/)
- **Goldsky Documentation:** [https://docs.goldsky.com/](https://docs.goldsky.com/)
