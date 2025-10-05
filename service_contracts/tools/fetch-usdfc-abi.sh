#!/usr/bin/env bash

#
# Fetches the ABI for a Filecoin proxy contract's implementation and saves it.
#
# Usage:
#   ./fetch-usdfc-abi.sh <PROXY_ADDRESS> [OUTPUT_PATH]
#
# Example:
#   ./fetch-usdfc-abi.sh 0x80B98d3aa09ffff255c3ba4A241111Ff1262F045 abi/Usdfc.abi.json
#

set -euo pipefail

# --- Helper Functions ---

# Function to exit with a formatted error message.
die() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

# --- Dependency Checks ---

# Ensure required command-line tools are installed.
for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    die "'$cmd' is not installed. Please install it to continue."
  fi
done

# --- Argument Parsing ---

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $0 <PROXY_ADDRESS> [OUTPUT_PATH]"
  exit 0
fi

# Check for required PROXY_ADDRESS argument.
if [[ -z "${1-}" ]]; then
  die "Missing required argument: PROXY_ADDRESS.\nUsage: $0 <PROXY_ADDRESS> [OUTPUT_PATH]"
fi

PROXY_ADDRESS=$1
# Use the second argument as the output path, or fall back to a default.
DEFAULT_OUTPUT_PATH="abi/Usdfc.abi.json"
OUTPUT_PATH=${2:-$DEFAULT_OUTPUT_PATH}

# --- Main Logic ---

# Create the output directory if it doesn't exist.
OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
if ! mkdir -p "$OUTPUT_DIR"; then
    die "Could not create output directory: $OUTPUT_DIR"
fi

# 1. Fetch the implementation address from the proxy contract.
API_URL="https://filfox.info/api/v1/address/${PROXY_ADDRESS}/contract"

# Use --fail to exit on HTTP errors (like 404), and a timeout to prevent hangs.
PROXY_RESPONSE=$(curl --silent --show-error --fail --connect-timeout 5 --max-time 15 "$API_URL") ||
  die "Failed to fetch data for proxy contract."

IMPLEMENTATION_ADDRESS=$(echo "$PROXY_RESPONSE" | jq -r '.proxyImpl')

if [[ -z "$IMPLEMENTATION_ADDRESS" || "$IMPLEMENTATION_ADDRESS" == "null" ]]; then
  die "Could not find implementation address ('proxyImpl') in API response."
fi

# 2. Fetch the ABI from the implementation contract.
IMPL_API_URL="https://filfox.info/api/v1/address/${IMPLEMENTATION_ADDRESS}/contract"

IMPL_RESPONSE=$(curl --silent --show-error --fail --connect-timeout 5 --max-time 15 "$IMPL_API_URL") ||
  die "Failed to fetch data for implementation contract."

# 3. Extract, parse, and save the ABI.
# This single command extracts the .abi string, parses it from a string into
# clean JSON, and saves it. It will fail if any step is unsuccessful.
echo "$IMPL_RESPONSE" | jq '.abi | fromjson' > "$OUTPUT_PATH" || {
  # Clean up the potentially empty/corrupt file on failure.
  rm -f "$OUTPUT_PATH" 2>/dev/null
  die "Failed to parse ABI. The '.abi' field may be missing, null, or not valid JSON."
}

echo "USDFC ABI saved successfully to $OUTPUT_PATH"