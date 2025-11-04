# Filecoin Services Scripts

This directory contains utility scripts for interacting with Filecoin Warm Storage Service contracts.

## Fault Status Query Scripts

Two equivalent scripts are provided for querying fault status:
- `query-fault-status.fish` - Fish shell version
- `query-fault-status.sh` - Bash version (more widely compatible)

Both scripts provide the same functionality to query and analyze the fault history of a dataset in the Filecoin Warm Storage Service.

### Features

- Queries the proving period fault bitmap from the contract
- Reconstructs complete fault history for all proving periods
- Calculates whether the provider is currently up to date with proving
- Determines how late the provider is if they missed deadlines
- Generates a detailed, color-coded report

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge/cast) installed
- Either Bash (usually pre-installed) or [Fish shell](https://fishshell.com/)
- Access to a Filecoin RPC endpoint

### Installation

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Fish (Ubuntu/Debian)
sudo apt-get install fish

# Or on macOS
brew install fish
```

### Usage

**Fish version:**
```fish
./query-fault-status.fish [OPTIONS] <dataSetId>
```

**Bash version:**
```bash
./query-fault-status.sh [OPTIONS] <dataSetId>
```

#### Arguments

- `<dataSetId>` - The dataset ID to query (required)

#### Options

- `-r, --rpc-url URL` - RPC endpoint URL (default: Calibration testnet)
- `-c, --contract ADDR` - Contract address (default: Calibration testnet address)
- `-p, --periods N` - Check only the N most recent periods (default: check all)
- `-v, --verbose` - Enable verbose output
- `-h, --help` - Show help message

### Examples

#### Query a dataset on Calibration testnet

```bash
./query-fault-status.sh 123
# or
./query-fault-status.fish 123
```

#### Query with custom RPC and contract

```bash
./query-fault-status.sh \
  --rpc-url https://api.node.glif.io/rpc/v1 \
  --contract 0x80617b65FD2EEa1D7fDe2B4F85977670690ed348 \
  456
```

#### Check only the most recent 50 periods

```bash
./query-fault-status.sh --periods 50 789
```

### Output

The script generates a comprehensive report including:

1. **Configuration Summary**
   - Dataset ID
   - Contract address
   - Current block number
   - Proving configuration (activation epoch, deadline, period length, challenge window)

2. **Proving Period Analysis**
   - Current proving period
   - Challenge window status
   - Whether deadline was missed and by how many blocks

3. **Fault History Table**
   - Period-by-period breakdown
   - Deadline for each period
   - Status (Proven/Faulted/Pending)

4. **Summary Statistics**
   - Total periods checked
   - Number of proven periods
   - Number of faulted periods
   - Fault rate percentage

### How It Works

#### Bitmap Decoding

The script queries the `provenPeriods` mapping which uses an optimized bitmap storage system:

- Each `uint256` stores 256 periods as individual bits
- `periodId >> 8` determines which storage bucket
- `periodId & 255` determines which bit within the bucket
- Bit value 1 = period was proven successfully
- Bit value 0 = period faulted (proof not submitted)

#### Contract Queries

The script makes the following RPC calls using `cast call`:

1. `provingActivationEpoch(uint256)` - When proving started
2. `provingDeadline(uint256)` - Current deadline block
3. `getMaxProvingPeriod()` - Length of each proving period
4. `challengeWindow()` - Size of the challenge window
5. `provenPeriods(uint256,uint256)` - Check if specific period was proven

#### Fault Detection

For each proving period:

1. Calculate the deadline: `activationEpoch + (periodId + 1) * maxProvingPeriod`
2. Query if the period was proven using `provenPeriods(dataSetId, periodId)`
3. If deadline has passed and period not proven → **FAULT**
4. If deadline has passed and period proven → **SUCCESS**
5. If deadline not yet reached → **PENDING**

### Technical Details

#### Proving Period Calculation

```
currentPeriod = (currentBlock - activationEpoch) / maxProvingPeriod
```

#### Challenge Window

The challenge window is the time period during which a provider can submit their proof:

```
challengeWindowStart = deadline - challengeWindowSize
```

Proofs can only be submitted when:
```
challengeWindowStart <= currentBlock <= deadline
```

#### Periods Missed

If the current block is past the deadline:

```
blocksOverdue = currentBlock - deadline
periodsMissed = floor(blocksOverdue / maxProvingPeriod)
```

### Troubleshooting

#### "cast: command not found"

Install Foundry:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

#### RPC connection errors

- Ensure the RPC URL is correct and accessible
- Try using a different RPC endpoint
- Check if you need authentication/API keys

#### "Failed to query contract state"

- Verify the contract address is correct
- Ensure the dataset ID exists
- Check that the RPC endpoint is synced

### Contract Addresses

#### Calibration Testnet (Default)
- **FilecoinWarmStorageService**: `0x80617b65FD2EEa1D7fDe2B4F85977670690ed348`
- **Network**: `filecoin-testnet`
- **RPC**: `https://api.calibration.node.glif.io/rpc/v1`

#### Mainnet
- Coming soon (see `subgraph/config/network.json` for latest addresses)

### Additional Documentation

- **[EXAMPLE_OUTPUT.md](./EXAMPLE_OUTPUT.md)** - Example outputs and how to interpret them
- **[BITMAP_REFERENCE.md](./BITMAP_REFERENCE.md)** - Technical deep-dive into the bitmap storage system

### Related Files

- Contract: `service_contracts/src/FilecoinWarmStorageService.sol`
- State View: `service_contracts/src/FilecoinWarmStorageServiceStateView.sol`
- Network Config: `subgraph/config/network.json`

### License

See [LICENSE.md](../LICENSE.md)
