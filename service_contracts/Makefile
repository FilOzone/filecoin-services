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
gen: check-tools $(LAYOUT) $(INTERNAL_LIB) $(VIEW_CONTRACT)
	@echo "Code generation complete"

# Force regeneration - useful when things are broken
.PHONY: force-gen
force-gen: clean-gen gen
	@echo "Force regeneration complete"

# Clean generated files only
.PHONY: clean-gen
clean-gen:
	@echo "Removing generated files..."
	@rm -f $(LAYOUT) $(INTERNAL_LIB) $(VIEW_CONTRACT)
	@rm -rf out/FilecoinWarmStorageServiceStateLibrary.sol
	@echo "Generated files removed"

# Safe regeneration - saves current state, attempts gen, restores on failure
.PHONY: safe-gen
safe-gen: check-tools
	@echo "Backing up current generated files..."
	@mkdir -p .backup-gen
	@cp -f $(LAYOUT) $(INTERNAL_LIB) $(VIEW_CONTRACT) .backup-gen/ 2>/dev/null || true
	@if $(MAKE) force-gen; then \
		echo "Generation successful"; \
		rm -rf .backup-gen; \
	else \
		echo "Generation failed, restoring backup..."; \
		cp -f .backup-gen/* . 2>/dev/null || true; \
		rm -rf .backup-gen; \
		exit 1; \
	fi

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

# Format code
.PHONY: fmt
fmt:
	forge fmt

# Check formatting
.PHONY: fmt-check
fmt-check:
	forge fmt --check

# Coverage
# Note: Using --ir-minimum due to "stack too deep" errors in Payments.sol
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

# Update checked-in ABIs
.PHONY: update-abi
update-abi: build
	@echo "Updating checked-in ABIs..."
	@mkdir -p abi
	@echo "  Extracting FilecoinWarmStorageService ABI..."
	@forge inspect FilecoinWarmStorageService abi --json > abi/FilecoinWarmStorageService.abi.json
	@echo "  Extracting FilecoinWarmStorageServiceStateView ABI..."
	@forge inspect FilecoinWarmStorageServiceStateView abi --json > abi/FilecoinWarmStorageServiceStateView.abi.json
	@echo "  Extracting FilecoinWarmStorageServiceStateLibrary ABI..."
	@forge inspect src/lib/FilecoinWarmStorageServiceStateLibrary.sol:FilecoinWarmStorageServiceStateLibrary abi --json > abi/FilecoinWarmStorageServiceStateLibrary.abi.json
	@echo "ABIs updated in abi/ directory"

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
	@echo "  safe-gen   - Attempt generation with automatic rollback on failure"
	@echo "  clean-gen  - Remove all generated files"
	@echo ""
	@echo "  help       - Show this help message"
	@echo "  contract-size-check - Check contract sizes against EIP-170 and EIP-3860 limits"
	@echo "  update-abi - Update checked-in ABIs in abi/ directory"
