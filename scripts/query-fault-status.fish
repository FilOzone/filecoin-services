#!/usr/bin/env fish

# Filecoin Warm Storage Service - Fault Status Query Script
# This script queries the fault history of a dataset by examining the provenPeriods bitmap
# and generating a comprehensive report on proving status.

set -g SCRIPT_NAME (basename (status filename))

# Default configuration
set -g DEFAULT_RPC_URL "https://api.calibration.node.glif.io/rpc/v1"
set -g DEFAULT_CONTRACT_ADDRESS "0xA5D87b04086B1d591026cCE10255351B5AA4689B"  # Calibration testnet state view contract

# Color codes for output
set -g COLOR_RESET "\033[0m"
set -g COLOR_BOLD "\033[1m"
set -g COLOR_RED "\033[31m"
set -g COLOR_GREEN "\033[32m"
set -g COLOR_YELLOW "\033[33m"
set -g COLOR_BLUE "\033[34m"
set -g COLOR_CYAN "\033[36m"

function print_usage
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
end

function error
    echo -e "$COLOR_RED""Error: $argv""$COLOR_RESET" >&2
end

function info
    echo -e "$COLOR_CYAN""$argv""$COLOR_RESET"
end

function success
    echo -e "$COLOR_GREEN""$argv""$COLOR_RESET"
end

function warning
    echo -e "$COLOR_YELLOW""$argv""$COLOR_RESET"
end

function bold
    echo -e "$COLOR_BOLD""$argv""$COLOR_RESET"
end

# Check if forge/cast is installed
function check_dependencies
    if not type -q cast
        error "cast (foundry) is not installed or not in PATH"
        error "Install from: https://book.getfoundry.sh/getting-started/installation"
        return 1
    end
    return 0
end

# Convert hex to decimal
function hex_to_dec
    set -l hex_value $argv[1]
    # Remove 0x prefix if present
    set hex_value (string replace -r '^0x' '' $hex_value)
    printf "%d" 0x$hex_value
end

# Call contract function
function call_contract
    set -l function_sig $argv[1]
    set -l args $argv[2..-1]

    if test (count $argv) -eq 1
        cast call $CONTRACT_ADDRESS "$function_sig" --rpc-url $RPC_URL 2>/dev/null
    else
        cast call $CONTRACT_ADDRESS "$function_sig" $args --rpc-url $RPC_URL 2>/dev/null
    end
end

# Get current block number
function get_current_block
    cast block-number --rpc-url $RPC_URL 2>/dev/null
end

# Query proving activation epoch
function get_proving_activation_epoch
    set -l dataset_id $argv[1]
    set -l result (call_contract "provingActivationEpoch(uint256)" $dataset_id)
    hex_to_dec $result
end

# Query proving deadline
function get_proving_deadline
    set -l dataset_id $argv[1]
    set -l result (call_contract "provingDeadline(uint256)" $dataset_id)
    hex_to_dec $result
end

# Query max proving period
function get_max_proving_period
    set -l result (call_contract "getMaxProvingPeriod()")
    hex_to_dec $result
end

# Query challenge window size
function get_challenge_window
    set -l result (call_contract "challengeWindow()")
    hex_to_dec $result
end

# Query proven periods bucket (internal mapping storage)
# NOTE: This function is for reference only and is not currently used.
# It would be inefficient to reconstruct the bitmap this way, and large exponents
# (2^255) could cause overflow issues.
function get_proven_periods_bucket
    set -l dataset_id $argv[1]
    set -l bucket_id $argv[2]

    # Calculate storage slot for provenPeriods[dataSetId][bucketId]
    # We need to query via the StateView contract if available
    # For now, we'll query individual periods using the view function

    # Query using provenPeriods view function for each bit in the bucket
    # WARNING: This is inefficient and may overflow for large bit positions
    set -l bucket_value 0
    for bit_pos in (seq 0 255)
        set -l period_id (math "$bucket_id * 256 + $bit_pos")
        set -l result (call_contract "provenPeriods(uint256,uint256)" $dataset_id $period_id)

        # If result is 0x0000...0001 then period is proven
        if test "$result" = "0x0000000000000000000000000000000000000000000000000000000000000001"
            # Set the corresponding bit (may overflow for large bit_pos)
            set bucket_value (math "$bucket_value + 2^$bit_pos")
        end
    end

    echo $bucket_value
end

# Check if a specific period is proven
function is_period_proven
    set -l dataset_id $argv[1]
    set -l period_id $argv[2]

    set -l result (call_contract "provenPeriods(uint256,uint256)" $dataset_id $period_id)

    if test "$result" = "0x0000000000000000000000000000000000000000000000000000000000000001"
        return 0  # true
    else
        return 1  # false
    end
end

# Calculate current proving period
function calculate_current_period
    set -l activation_epoch $argv[1]
    set -l current_epoch $argv[2]
    set -l max_proving_period $argv[3]

    if test $activation_epoch -eq 0
        echo -1
        return
    end

    if test $current_epoch -lt $activation_epoch
        echo -1
        return
    end

    set -l epochs_since_activation (math "$current_epoch - $activation_epoch")
    # Fish math does integer division by default (automatic floor)
    set -l current_period (math "$epochs_since_activation / $max_proving_period")
    echo $current_period
end

# Calculate deadline for a specific period
function calculate_period_deadline
    set -l activation_epoch $argv[1]
    set -l period_id $argv[2]
    set -l max_proving_period $argv[3]

    set -l deadline (math "$activation_epoch + ($period_id + 1) * $max_proving_period")
    echo $deadline
end

# Main query function
function query_fault_status
    set -l dataset_id $argv[1]

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
    set -l current_block (get_current_block)
    if test -z "$current_block"
        error "Failed to get current block number"
        return 1
    end
    success "✓ Current block: $current_block"
    echo ""

    # Get proving configuration
    info "Querying proving configuration..."
    set -l activation_epoch (get_proving_activation_epoch $dataset_id)
    set -l proving_deadline (get_proving_deadline $dataset_id)
    set -l max_proving_period (get_max_proving_period)
    set -l challenge_window (get_challenge_window)

    if test -z "$activation_epoch" -o -z "$proving_deadline" -o -z "$max_proving_period" -o -z "$challenge_window"
        error "Failed to query contract state"
        return 1
    end

    success "✓ Proving configuration retrieved"
    echo "  Activation Epoch: $activation_epoch"
    echo "  Current Deadline: $proving_deadline"
    echo "  Max Proving Period: $max_proving_period epochs"
    echo "  Challenge Window: $challenge_window epochs"
    echo ""

    # Check if proving is active
    if test $proving_deadline -eq 0
        warning "⚠ Proving has not been activated for this dataset"
        return 0
    end

    if test $activation_epoch -eq 0 -o $activation_epoch -gt $current_block
        warning "⚠ Proving not yet started (activation epoch not reached)"
        return 0
    end

    # Calculate current period
    set -l current_period (calculate_current_period $activation_epoch $current_block $max_proving_period)

    if test $current_period -lt 0
        warning "⚠ Invalid period calculation"
        return 1
    end

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Proving Period Analysis"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "Current Period: $current_period"

    # Calculate challenge window
    set -l challenge_window_start (math "$proving_deadline - $challenge_window")
    echo "Challenge Window: blocks $challenge_window_start to $proving_deadline"

    # Check if we're in the challenge window
    if test $current_block -ge $challenge_window_start -a $current_block -le $proving_deadline
        success "✓ Currently in challenge window"
    else if test $current_block -gt $proving_deadline
        set -l blocks_overdue (math "$current_block - $proving_deadline")
        # Fish math does integer division by default (automatic floor)
        set -l periods_missed (math "$blocks_overdue / $max_proving_period")
        warning "⚠ DEADLINE MISSED by $blocks_overdue blocks ($periods_missed period(s))"
    else
        info "○ Not yet in challenge window (starts at block $challenge_window_start)"
    end
    echo ""

    # Check how many periods to scan
    set -l start_period 0
    set -l end_period $current_period

    if test $MAX_PERIODS -gt 0
        # Check the N most recent periods
        set start_period (math "max(0, $current_period - $MAX_PERIODS + 1)")
    end

    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Fault History (Periods $start_period to $end_period)"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    set -l num_periods (math "$end_period - $start_period + 1")
    info "Scanning $num_periods proving periods..."
    echo ""

    set -l total_periods 0
    set -l proven_count 0
    set -l faulted_count 0
    set -l faulted_periods

    printf "%-10s %-15s %-15s %-10s\n" "Period" "Deadline" "Status" "Result"
    echo "────────────────────────────────────────────────────────────"

    for period_id in (seq $start_period $end_period)
        set -l period_deadline (calculate_period_deadline $activation_epoch $period_id $max_proving_period)

        # Only check periods whose deadline has passed
        if test $period_deadline -le $current_block
            set total_periods (math "$total_periods + 1")
            if is_period_proven $dataset_id $period_id
                set proven_count (math "$proven_count + 1")
                printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Checked"
                success "✓ PROVEN"
            else
                set faulted_count (math "$faulted_count + 1")
                set -a faulted_periods $period_id
                printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Checked"
                error "✗ FAULTED"
            end
        else
            printf "%-10s %-15s %-15s " "$period_id" "$period_deadline" "Pending"
            echo "○ Not yet due"
        end
    end

    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  Summary"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "Total Periods Checked: $total_periods"
    success "Proven Periods: $proven_count"

    if test $faulted_count -gt 0
        error "Faulted Periods: $faulted_count"
        echo ""
        warning "Faulted Period IDs: $faulted_periods"
    else
        success "Faulted Periods: 0"
    end

    echo ""

    if test $faulted_count -eq 0
        success "✓ NO FAULTS DETECTED - All checked periods proven successfully"
    else
        # Calculate fault rate with 2 decimal places
        # Fish math doesn't support floating point directly, so we calculate as integer then format
        set -l fault_rate_scaled (math "$faulted_count * 10000 / $total_periods")
        set -l fault_rate_whole (math "$fault_rate_scaled / 100")
        set -l fault_rate_decimal (math "$fault_rate_scaled % 100")
        # Pad decimal part to 2 digits
        if test $fault_rate_decimal -lt 10
            set fault_rate_decimal "0$fault_rate_decimal"
        end
        warning "⚠ FAULTS DETECTED - Fault rate: $fault_rate_whole.$fault_rate_decimal%"
    end

    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    return 0
end

# Parse command line arguments
set -g RPC_URL $DEFAULT_RPC_URL
set -g CONTRACT_ADDRESS $DEFAULT_CONTRACT_ADDRESS
set -g MAX_PERIODS 0
set -g VERBOSE 0
set -g DATASET_ID ""

set -l i 1
while test $i -le (count $argv)
    set -l arg $argv[$i]

    switch $arg
        case -h --help
            print_usage
            exit 0

        case -r --rpc-url
            set i (math "$i + 1")
            if test $i -le (count $argv)
                set RPC_URL $argv[$i]
            else
                error "Missing value for $arg"
                exit 1
            end

        case -c --contract
            set i (math "$i + 1")
            if test $i -le (count $argv)
                set CONTRACT_ADDRESS $argv[$i]
            else
                error "Missing value for $arg"
                exit 1
            end

        case -p --periods
            set i (math "$i + 1")
            if test $i -le (count $argv)
                set MAX_PERIODS $argv[$i]
            else
                error "Missing value for $arg"
                exit 1
            end

        case -v --verbose
            set VERBOSE 1

        case '*'
            if test -z "$DATASET_ID"
                set DATASET_ID $arg
            else
                error "Unexpected argument: $arg"
                print_usage
                exit 1
            end
    end

    set i (math "$i + 1")
end

# Validate required arguments
if test -z "$DATASET_ID"
    error "Missing required argument: <dataSetId>"
    echo ""
    print_usage
    exit 1
end

# Main execution
check_dependencies
or exit 1

query_fault_status $DATASET_ID
