#!/usr/bin/env bash

# Filecoin Warm Storage Service - Fault Status Query Script
# This script queries the fault history of a dataset by examining the provenPeriods bitmap
# and generating a comprehensive report on proving status.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Default configuration
DEFAULT_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
DEFAULT_CONTRACT_ADDRESS="0xA5D87b04086B1d591026cCE10255351B5AA4689B"  # Calibration testnet

# Color codes for output
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_CYAN="\033[36m"

function print_usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS] <dataSetId>"
    echo ""
    echo "Query the fault status of a Filecoin Warm Storage Service dataset."
    echo ""
    echo "Arguments:"
    echo "  <dataSetId>          The dataset ID to query (required)"
    echo ""
    echo "Options:"
    echo "  -r, --rpc-url URL    RPC endpoint URL (default: calibration testnet)"
    echo "  -c, --contract ADDR  Contract address (default: calibration testnet)"
    echo "  -p, --periods N      Check only the N most recent periods (default: check all)"
    echo "  -v, --verbose        Enable verbose output"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME 123"
    echo "  $SCRIPT_NAME --rpc-url https://api.node.glif.io/rpc/v1 --contract 0x... 456"
    echo "  $SCRIPT_NAME -p 100 789"
}

function error() {
    echo -e "${COLOR_RED}Error: $*${COLOR_RESET}" >&2
}

function info() {
    echo -e "${COLOR_CYAN}$*${COLOR_RESET}"
}

function success() {
    echo -e "${COLOR_GREEN}$*${COLOR_RESET}"
}

function warning() {
    echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"
}

function bold() {
    echo -e "${COLOR_BOLD}$*${COLOR_RESET}"
}

# Check if forge/cast is installed
function check_dependencies() {
    if ! command -v cast &> /dev/null; then
        error "cast (foundry) is not installed or not in PATH"
        error "Install from: https://book.getfoundry.sh/getting-started/installation"
        return 1
    fi
    return 0
}

# Convert hex to decimal
function hex_to_dec() {
    local hex_value=$1
    # Remove 0x prefix if present
    hex_value=${hex_value#0x}
    printf "%d" $((16#$hex_value))
}

# Call contract function
function call_contract() {
    local function_sig=$1
    shift

    if [ $# -eq 0 ]; then
        cast call "$CONTRACT_ADDRESS" "$function_sig" --rpc-url "$RPC_URL" 2>/dev/null
    else
        cast call "$CONTRACT_ADDRESS" "$function_sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null
    fi
}

# Get current block number
function get_current_block() {
    cast block-number --rpc-url "$RPC_URL" 2>/dev/null
}

# Query proving activation epoch
function get_proving_activation_epoch() {
    local dataset_id=$1
    local result
    result=$(call_contract "provingActivationEpoch(uint256)" "$dataset_id")
    hex_to_dec "$result"
}

# Query proving deadline
function get_proving_deadline() {
    local dataset_id=$1
    local result
    result=$(call_contract "provingDeadline(uint256)" "$dataset_id")
    hex_to_dec "$result"
}

# Query max proving period
function get_max_proving_period() {
    local result
    result=$(call_contract "getMaxProvingPeriod()")
    hex_to_dec "$result"
}

# Query challenge window size
function get_challenge_window() {
    local result
    result=$(call_contract "challengeWindow()")
    hex_to_dec "$result"
}

# Check if a specific period is proven
function is_period_proven() {
    local dataset_id=$1
    local period_id=$2
    local result

    result=$(call_contract "provenPeriods(uint256,uint256)" "$dataset_id" "$period_id")

    if [ "$result" = "0x0000000000000000000000000000000000000000000000000000000000000001" ]; then
        return 0  # true
    else
        return 1  # false
    fi
}

# Calculate current proving period
function calculate_current_period() {
    local activation_epoch=$1
    local current_epoch=$2
    local max_proving_period=$3

    if [ "$activation_epoch" -eq 0 ]; then
        echo -1
        return
    fi

    if [ "$current_epoch" -lt "$activation_epoch" ]; then
        echo -1
        return
    fi

    local epochs_since_activation=$((current_epoch - activation_epoch))
    local current_period=$((epochs_since_activation / max_proving_period))
    echo "$current_period"
}

# Calculate deadline for a specific period
function calculate_period_deadline() {
    local activation_epoch=$1
    local period_id=$2
    local max_proving_period=$3

    local deadline=$((activation_epoch + (period_id + 1) * max_proving_period))
    echo "$deadline"
}

# Main query function
function query_fault_status() {
    local dataset_id=$1

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Filecoin Warm Storage Service - Fault Status Report"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    info "Dataset ID: $dataset_id"
    info "Contract: $CONTRACT_ADDRESS"
    info "RPC: $RPC_URL"
    echo ""

    # Get current block number
    info "Fetching current block number..."
    local current_block
    current_block=$(get_current_block)
    if [ -z "$current_block" ]; then
        error "Failed to get current block number"
        return 1
    fi
    success "✓ Current block: $current_block"
    echo ""

    # Get proving configuration
    info "Querying proving configuration..."
    local activation_epoch proving_deadline max_proving_period challenge_window
    activation_epoch=$(get_proving_activation_epoch "$dataset_id")
    proving_deadline=$(get_proving_deadline "$dataset_id")
    max_proving_period=$(get_max_proving_period)
    challenge_window=$(get_challenge_window)

    if [ -z "$activation_epoch" ] || [ -z "$proving_deadline" ] || [ -z "$max_proving_period" ] || [ -z "$challenge_window" ]; then
        error "Failed to query contract state"
        return 1
    fi

    success "✓ Proving configuration retrieved"
    echo "  Activation Epoch: $activation_epoch"
    echo "  Current Deadline: $proving_deadline"
    echo "  Max Proving Period: $max_proving_period epochs"
    echo "  Challenge Window: $challenge_window epochs"
    echo ""

    # Check if proving is active
    if [ "$proving_deadline" -eq 0 ]; then
        warning "⚠ Proving has not been activated for this dataset"
        return 0
    fi

    if [ "$activation_epoch" -eq 0 ] || [ "$activation_epoch" -gt "$current_block" ]; then
        warning "⚠ Proving not yet started (activation epoch not reached)"
        return 0
    fi

    # Calculate current period
    local current_period
    current_period=$(calculate_current_period "$activation_epoch" "$current_block" "$max_proving_period")

    if [ "$current_period" -lt 0 ]; then
        warning "⚠ Invalid period calculation"
        return 1
    fi

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Proving Period Analysis"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "Current Period: $current_period"

    # Calculate challenge window
    local challenge_window_start=$((proving_deadline - challenge_window))
    echo "Challenge Window: blocks $challenge_window_start to $proving_deadline"

    # Check if we're in the challenge window
    if [ "$current_block" -ge "$challenge_window_start" ] && [ "$current_block" -le "$proving_deadline" ]; then
        success "✓ Currently in challenge window"
    elif [ "$current_block" -gt "$proving_deadline" ]; then
        local blocks_overdue=$((current_block - proving_deadline))
        local periods_missed=$((blocks_overdue / max_proving_period))
        warning "⚠ DEADLINE MISSED by $blocks_overdue blocks ($periods_missed period(s))"
    else
        info "○ Not yet in challenge window (starts at block $challenge_window_start)"
    fi
    echo ""

    # Check how many periods to scan
    local start_period=0
    local end_period=$current_period

    if [ "$MAX_PERIODS" -gt 0 ]; then
        # Check the N most recent periods
        local temp=$((current_period - MAX_PERIODS + 1))
        start_period=$((temp > 0 ? temp : 0))
    fi

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Fault History (Periods $start_period to $end_period)"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local num_periods=$((end_period - start_period + 1))
    info "Scanning $num_periods proving periods..."
    echo ""

    printf "%-10s %-15s %-15s %-10s\n" "Period" "Deadline" "Status" "Result"
    echo "────────────────────────────────────────────────────────────"

    local total_periods=0
    local proven_count=0
    local faulted_count=0
    local faulted_periods=()

    for period_id in $(seq "$start_period" "$end_period"); do
        local period_deadline
        period_deadline=$(calculate_period_deadline "$activation_epoch" "$period_id" "$max_proving_period")

        # Only check periods whose deadline has passed
        if [ "$period_deadline" -le "$current_block" ]; then
            total_periods=$((total_periods + 1))
            if is_period_proven "$dataset_id" "$period_id"; then
                proven_count=$((proven_count + 1))
                printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Checked"
                success "✓ PROVEN"
            else
                faulted_count=$((faulted_count + 1))
                faulted_periods+=("$period_id")
                printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Checked"
                error "✗ FAULTED"
            fi
        else
            printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Pending"
            echo "○ Not yet due"
        fi
    done

    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Summary"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "Total Periods Checked: $total_periods"
    success "Proven Periods: $proven_count"

    if [ "$faulted_count" -gt 0 ]; then
        error "Faulted Periods: $faulted_count"
        echo ""
        warning "Faulted Period IDs: ${faulted_periods[*]}"
    else
        success "Faulted Periods: 0"
    fi

    echo ""

    if [ "$faulted_count" -eq 0 ]; then
        success "✓ NO FAULTS DETECTED - All checked periods proven successfully"
    else
        local fault_rate
        fault_rate=$(awk "BEGIN {printf \"%.2f\", $faulted_count * 100 / $total_periods}")
        warning "⚠ FAULTS DETECTED - Fault rate: ${fault_rate}%"
    fi

    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    return 0
}

# Parse command line arguments
RPC_URL=$DEFAULT_RPC_URL
CONTRACT_ADDRESS=$DEFAULT_CONTRACT_ADDRESS
MAX_PERIODS=0
VERBOSE=0
DATASET_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -r|--rpc-url)
            RPC_URL="$2"
            shift 2
            ;;
        -c|--contract)
            CONTRACT_ADDRESS="$2"
            shift 2
            ;;
        -p|--periods)
            MAX_PERIODS="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -*)
            error "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            if [ -z "$DATASET_ID" ]; then
                DATASET_ID="$1"
            else
                error "Unexpected argument: $1"
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$DATASET_ID" ]; then
    error "Missing required argument: <dataSetId>"
    echo ""
    print_usage
    exit 1
fi

# Main execution
check_dependencies || exit 1

query_fault_status "$DATASET_ID"
