# Filecoin Payment Services Tools

A place for all tools related to deploying, upgrading, and managing the Payments contract.

## Tools

### Available Tools

- **Deployment Script**: `deploy.sh` (all networks)

### Deployment Script

#### deploy.sh
This script deploys the Payments contract to the specified network. Usage:

```bash
./tools/deploy.sh <chain_id>
# Example: 314159 (calibnet), 314 (mainnet), 12345 (devnet)
```
- Uses `PAYMENTS_PATH` if set, otherwise defaults to `src/Payments.sol:Payments`.
- Sets a default `RPC_URL` if not provided, based on `CHAIN_ID`.
- Outputs the Payments Contract Address (proxy) and Implementation Address.

### Environment Variables

To use these scripts, set the following environment variables:
- `RPC_URL` - The RPC URL for the network. For Calibration Testnet (314159) and Mainnet (314), a default is set if not provided. For devnet or any custom CHAIN_ID, you must set `RPC_URL` explicitly.
- `KEYSTORE` - Path to the keystore file
- `PASSWORD` - Password for the keystore
- `PAYMENTS_PATH` - Path to the implementation contract (e.g., "src/Payments.sol:Payments")

### Make Targets

```bash
# Deployment
make deploy-devnet                  # Deploy to local devnet
make deploy-calibnet                # Deploy to Calibration Testnet
make deploy-mainnet                 # Deploy to Mainnet
```

---

### Direct Script Usage (without Make)

You can run all scripts directly from the `tools/` directory without using Makefile targets.  
Set the required environment variables as shown below, then invoke the scripts with the appropriate arguments.

**Note:**  
- For Calibration Testnet (314159) and Mainnet (314), the script sets a default `RPC_URL` if not provided.  
- For devnet or any custom `CHAIN_ID`, you must set `RPC_URL` explicitly or the script will exit with an error.  
- You can always inspect each script for more details on required and optional environment variables.

#### Deploy

```bash
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
# Optionally set PAYMENTS_PATH and RPC_URL
./tools/deploy.sh <chain_id>
# Example: ./tools/deploy.sh 314159
```

### Example Usage

```bash
# Deploy to calibnet
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
make deploy-calibnet
``` 
