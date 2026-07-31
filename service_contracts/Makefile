# Makefile for Service Contracts

# Variables
RPC_URL ?=
KEYSTORE ?=
PASSWORD ?=
CHALLENGE_FINALITY ?=

# Default target
.PHONY: default
default: build test

# All target including installation
.PHONY: all
all: install build test

# Install dependencies
.PHONY: install
install:
	forge install

# Generated files
LAYOUT=src/lib/FilecoinWarmStorageServiceLayout.sol
LAYOUT_JSON=src/lib/FilecoinWarmStorageServiceLayout.json
LAYOUT_SNAPSHOT_JQ=tools/storage_layout_snapshot.jq
INTERNAL_LIB=src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol
VIEW_CONTRACT=src/FilecoinWarmStorageServiceStateView.sol
LIBRARY_JSON=out/FilecoinWarmStorageServiceStateLibrary.sol/FilecoinWarmStorageServiceStateLibrary.json

# Build target
.PHONY: build
build:
	forge build --via-ir

# Storage layout generation
$(LAYOUT): tools/generate_storage_layout.sh src/FilecoinWarmStorageService.sol
	$^ | forge fmt -r - > $@

# Storage layout JSON (full metadata for upgrade safety checks)
$(LAYOUT_JSON): src/FilecoinWarmStorageService.sol $(LAYOUT_SNAPSHOT_JQ)
	forge inspect --json $< storageLayout | jq -f $(LAYOUT_SNAPSHOT_JQ) > $@

# JSON compilation for library (depends on the source library)
$(LIBRARY_JSON): src/lib/FilecoinWarmStorageServiceStateLibrary.sol
	forge build --via-ir $^

# View contract generation (depends on JSON)
$(VIEW_CONTRACT): tools/generate_view_contract.sh $(LIBRARY_JSON)
	$^ | forge fmt -r - > $@

# Internal library generation (simple sed transform)
%StateInternalLibrary.sol: %StateLibrary.sol
	sed -e 's/public/internal/g' -e 's/StateLibrary/StateInternalLibrary/g' $< | awk 'NR == 4 { print "// Code generated - DO NOT EDIT.\n// This file is a generated binding and any changes will be lost.\n// Generated with make $@\n"} {print}' | forge fmt -r - > $@

# Main code generation target with proper dependencies
.PHONY: gen
gen: check-tools $(LAYOUT) $(LAYOUT_JSON) $(INTERNAL_LIB) $(VIEW_CONTRACT)
	@echo "Code generation complete"

# Force regeneration - useful when things are broken
.PHONY: force-gen
force-gen: clean-gen gen
	@echo "Force regeneration complete"

# Clean generated files only
.PHONY: clean-gen
clean-gen:
	@echo "Removing generated files..."
	@rm -f $(LAYOUT) $(LAYOUT_JSON) $(INTERNAL_LIB) $(VIEW_CONTRACT)
	@rm -rf out/FilecoinWarmStorageServiceStateLibrary.sol
	@echo "Generated files removed"

# Check required tools
.PHONY: check-tools
check-tools:
	@which jq >/dev/null 2>&1 || (echo "Error: jq is required but not installed" && exit 1)
	@JQ_VERSION=$$(jq --version 2>/dev/null | sed 's/jq-//'); \
	MAJOR=$$(echo $$JQ_VERSION | cut -d. -f1); \
	MINOR=$$(echo $$JQ_VERSION | cut -d. -f2); \
	if [ "$$MAJOR" -lt 1 ] || ([ "$$MAJOR" -eq 1 ] && [ "$$MINOR" -lt 7 ]); then \
		echo "Warning: jq version $$JQ_VERSION detected. Version 1.7+ recommended for full functionality"; \
	fi
	@which forge >/dev/null 2>&1 || (echo "Error: forge is required but not installed" && exit 1)

# Test target
.PHONY: test
test:
	forge test --via-ir -vv

# Clean build artifacts
.PHONY: clean
clean:
	forge clean
	rm -rf out cache

# Clean everything including generated files and ABIs
.PHONY: clean-all
clean-all: clean clean-gen clean-abi
	@echo "All artifacts cleaned"

# Format code
.PHONY: fmt
fmt:
	forge fmt

# Check formatting
.PHONY: fmt-check
fmt-check:
	forge fmt --check

# Coverage
# Note: Using --ir-minimum due to "stack too deep" errors in FilecoinPayV1.sol
# This may result in less accurate source mappings but is necessary for coverage to run
.PHONY: coverage
coverage:
	@echo "Running coverage with --ir-minimum (required due to stack depth issues)..."
	forge coverage --ir-minimum --report summary

# Coverage with LCOV report (for CI)
.PHONY: coverage-lcov
coverage-lcov:
	@echo "Generating LCOV coverage report with --ir-minimum..."
	forge coverage --ir-minimum --report lcov

.PHONY: contract-size-check
contract-size-check:
	@echo "Checking contract sizes..."
	bash tools/check-contract-size.sh src/

# Storage layout validation
.PHONY: check-layout
check-layout:
	@echo "Checking storage layout for destructive changes..."
	@bash tools/check_storage_layout.sh

# ABI Management

# Core contracts we publish ABIs for.
ABI_CONTRACTS := \
	FilecoinWarmStorageService \
	IFilecoinServiceMetadata \
	FilecoinWarmStorageServiceStateLibrary \
	FilecoinWarmStorageServiceStateView \
	FilecoinPayV1 \
	PDPVerifier \
	ProviderIdSet \
	ServiceProviderRegistry \
	ServiceProviderRegistryStorage \
	SessionKeyRegistry \
	Errors

# Contract ABIs that should include event fragments emitted from first-party
# libraries. Library events are logged from the calling contract/proxy address.
ABI_CONTRACTS_WITH_LIBRARY_EVENTS := FilecoinWarmStorageService
ABI_CONTRACTS_SIMPLE := $(filter-out $(ABI_CONTRACTS_WITH_LIBRARY_EVENTS),$(ABI_CONTRACTS))
FIRST_PARTY_LIBRARY_SOURCE_PREFIX := src/lib/

# Directory for ABIs
abi:
	@mkdir -p abi

# Update ABIs
.PHONY: update-abi
update-abi: | abi
	forge build --via-ir
	@set -e; for contract in $(ABI_CONTRACTS_SIMPLE); do \
		artifact="out/$$contract.sol/$$contract.json"; \
		echo "Extracting ABI for $$contract..."; \
		jq '.abi' "$$artifact" > "abi/$$contract.abi.json"; \
	done
	@jq -s --arg source_prefix "$(FIRST_PARTY_LIBRARY_SOURCE_PREFIX)" \
		'def solc_metadata: if (.metadata | type) == "string" then (.metadata | try fromjson catch {}) else (.metadata // {}) end; def abi_key: (.type // "") + ":" + (.name // "") + ":" + ([.inputs[]? | (.type // "")] | join(",")); reduce ([.[] | select((((solc_metadata.settings.compilationTarget // {}) | to_entries[0]? | .key // "") | startswith($$source_prefix))) | (.abi // [])[] | select(.type == "event")][]) as $$event ([]; if any(.[]; abi_key == ($$event | abi_key)) then . else . + [$$event] end)' \
		out/*.sol/*.json > abi/.library-events.abi.json
	@set -e; for contract in $(ABI_CONTRACTS_WITH_LIBRARY_EVENTS); do \
		artifact="out/$$contract.sol/$$contract.json"; \
		echo "Extracting ABI for $$contract with first-party library events..."; \
		jq -s \
			'def abi_key: (.type // "") + ":" + (.name // "") + ":" + ([.inputs[]? | (.type // "")] | join(",")); .[0].abi as $$contract_abi | .[1] as $$library_events | reduce $$library_events[] as $$event ($$contract_abi; if any(.[]; abi_key == ($$event | abi_key)) then . else . + [$$event] end)' \
			"$$artifact" abi/.library-events.abi.json > "abi/$$contract.abi.json.tmp"; \
		mv "abi/$$contract.abi.json.tmp" "abi/$$contract.abi.json"; \
	done
	@rm -f abi/.library-events.abi.json

# Clean just the ABIs
.PHONY: clean-abi
clean-abi:
	@rm -f abi/*.abi.json

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  install    - Install dependencies (forge and npm)"
	@echo "  build      - Build contracts"
	@echo "  test       - Run tests"
	@echo "  clean      - Clean build artifacts"
	@echo "  fmt        - Format code"
	@echo "  fmt-check  - Check code formatting"
	@echo "  coverage   - Generate test coverage summary (uses --ir-minimum)"
	@echo "  coverage-lcov - Generate LCOV coverage report for CI"
	@echo ""
	@echo "Code generation targets:"
	@echo "  gen        - Generate code (layout, internal lib, view contract)"
	@echo "  force-gen  - Clean and regenerate all files (use when broken)"
	@echo "  clean-gen  - Remove all generated files"
	@echo ""
	@echo "Validation targets:"
	@echo "  check-layout - Check storage layout for destructive changes (full metadata comparison)"
	@echo "  contract-size-check - Check contract sizes against EIP-170 and EIP-3860 limits"
	@echo ""
	@echo "  help       - Show this help message"
	@echo ""
	@echo "ABI management targets:"
	@echo "  update-abi - Update checked-in ABIs in abi/ directory from an incremental build"
	@echo "  clean-abi  - Remove all ABI files"
	@echo ""
	@echo "Full cleanup:"
	@echo "  clean-all  - Remove all artifacts (build, generated, ABIs)"
