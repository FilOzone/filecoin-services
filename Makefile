# Unified Makefile for Filecoin Services Monorepo
# Consolidates all package tools and provides unified interface

# Variables
RPC_URL ?=
KEYSTORE ?=
PASSWORD ?=
CHALLENGE_FINALITY ?=
VERBOSE ?= false

# Package directories
PACKAGES := pay pdp session-key-registry warm-storage

# Default target
.PHONY: default
default: build test

# All target including installation
.PHONY: all
all: install build test

# =============================================================================
# INSTALLATION & SETUP
# =============================================================================

.PHONY: install
install:
	@echo "Installing npm dependencies..."
	npm install
	@echo "Building forge dependencies..."
	forge build
	@echo "Dependencies installed and built successfully!"

.PHONY: install-npm
install-npm:
	npm install

.PHONY: install-forge
install-forge:
	forge install

# =============================================================================
# BUILD & COMPILATION
# =============================================================================

.PHONY: build
build:
	@echo "Building all packages..."
	forge build

.PHONY: build-pay
build-pay:
	@echo "Building pay package..."
	forge build packages/pay

.PHONY: build-pdp
build-pdp:
	@echo "Building pdp package..."
	forge build packages/pdp

.PHONY: build-session-key
build-session-key:
	@echo "Building session-key-registry package..."
	forge build packages/session-key-registry

.PHONY: build-warm-storage
build-warm-storage:
	@echo "Building warm-storage package..."
	forge build packages/warm-storage

# =============================================================================
# TESTING
# =============================================================================

.PHONY: test
test:
	@echo "Running all tests..."
	forge test

.PHONY: test-pay
test-pay:
	@echo "Testing pay package..."
	forge test --match-path 'packages/pay/**/*.t.sol'

.PHONY: test-pdp
test-pdp:
	@echo "Testing pdp package..."
	forge test --match-path 'packages/pdp/**/*.t.sol'

.PHONY: test-session-key
test-session-key:
	@echo "Testing session-key-registry package..."
	forge test --match-path 'packages/session-key-registry/**/*.t.sol'

.PHONY: test-warm-storage
test-warm-storage:
	@echo "Testing warm-storage package..."
	forge test --match-path 'packages/warm-storage/**/*.t.sol'

.PHONY: test-verbose
test-verbose:
	@echo "Running all tests with verbose output..."
	forge test --verbosity 2

.PHONY: test-gas
test-gas:
	@echo "Running tests with gas report..."
	forge test --gas-report

.PHONY: test-coverage
test-coverage:
	@echo "Running test coverage..."
	forge coverage

# =============================================================================
# LINTING & FORMATTING
# =============================================================================

.PHONY: lint
lint:
	@echo "Checking code formatting..."
	forge fmt --check

.PHONY: format
format:
	@echo "Formatting code..."
	forge fmt

.PHONY: lint-fix
lint-fix: format

# =============================================================================
# CLEANUP
# =============================================================================

.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	forge clean
	rm -rf node_modules
	rm -rf abi

.PHONY: clean-cache
clean-cache:
	@echo "Cleaning cache..."
	forge clean

.PHONY: clean-deps
clean-deps:
	@echo "Cleaning dependencies..."
	rm -rf node_modules

.PHONY: clean-all
clean-all: clean clean-gen
	@echo "All artifacts cleaned"

# =============================================================================
# ABI EXTRACTION
# =============================================================================

# Extract just the ABI arrays into abi/ContractName.abi.json
.PHONY: extract-abis
extract-abis:
	mkdir -p abi
	@find out -type f -name '*.json' | while read file; do \
	  name=$$(basename "$${file%.*}"); \
	  jq '.abi' "$${file}" > "abi/$${name}.abi.json"; \
	done

# =============================================================================
# CONTRACT SIZE CHECKING
# =============================================================================

.PHONY: size-check
size-check:
	@echo "Checking contract sizes..."
	forge build --sizes

.PHONY: size-check-pay
size-check-pay: build-pay
	@echo "Checking pay package contract sizes..."
	forge build --sizes packages/pay

.PHONY: size-check-pdp
size-check-pdp: build-pdp
	@echo "Checking pdp package contract sizes..."
	forge build --sizes packages/pdp

.PHONY: size-check-session-key
size-check-session-key: build-session-key
	@echo "Checking session-key-registry package contract sizes..."
	forge build --sizes packages/session-key-registry

.PHONY: size-check-warm-storage
size-check-warm-storage: build-warm-storage
	@echo "Checking warm-storage package contract sizes..."
	forge build --sizes packages/warm-storage

# =============================================================================
# UTILITY TARGETS
# =============================================================================

.PHONY: help
help:
	@echo "Filecoin Services Monorepo - Available targets:"
	@echo ""
	@echo "Setup & Installation:"
	@echo "  install          - Install all dependencies (npm + forge)"
	@echo "  install-npm      - Install npm dependencies only"
	@echo "  install-forge    - Install forge dependencies only"
	@echo "  dev-setup        - Complete development environment setup"
	@echo ""
	@echo "Building:"
	@echo "  build            - Build all packages"
	@echo "  build-pay        - Build pay package only"
	@echo "  build-pdp        - Build pdp package only"
	@echo "  build-session-key- Build session-key-registry package only"
	@echo "  build-warm-storage- Build warm-storage package only"
	@echo ""
	@echo "Testing:"
	@echo "  test             - Run all tests"
	@echo "  test-pay         - Test pay package only"
	@echo "  test-pdp         - Test pdp package only"
	@echo "  test-session-key - Test session-key-registry package only"
	@echo "  test-warm-storage- Test warm-storage package only"
	@echo "  test-verbose     - Run all tests with verbose output"
	@echo "  test-gas         - Run tests with gas report"
	@echo "  test-coverage    - Run test coverage"
	@echo "  coverage         - Run coverage with --ir-minimum"
	@echo "  coverage-lcov    - Generate LCOV coverage report"
	@echo ""
	@echo "Code Quality:"
	@echo "  lint             - Check code formatting"
	@echo "  format           - Format code"
	@echo "  lint-fix         - Alias for format"
	@echo "  pre-commit       - Run pre-commit checks (format, lint, test, size-check)"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean            - Clean build artifacts and dependencies"
	@echo "  clean-cache      - Clean forge cache only"
	@echo "  clean-deps       - Clean npm dependencies only"
	@echo "  clean-all        - Clean all artifacts (build, generated files)"
	@echo "  clean-gen        - Clean generated files"
	@echo ""
	@echo "ABI Extraction:"
	@echo "  extract-abis     - Extract ABIs from all packages"
	@echo ""
	@echo "Contract Size:"
	@echo "  size-check       - Check contract sizes for all packages"
	@echo "  size-check-pay   - Check contract sizes for pay package"
	@echo "  size-check-pdp   - Check contract sizes for pdp package"
	@echo "  size-check-session-key - Check contract sizes for session-key-registry"
	@echo "  size-check-warm-storage - Check contract sizes for warm-storage"
	@echo "  contract-size-check - Check contract sizes using warm-storage tools"
	@echo ""
	@echo "Code Generation:"
	@echo "  gen              - Generate code (storage layout, view contracts)"
	@echo "  force-gen        - Force regeneration of all generated files"
	@echo "  check-tools      - Check required tools (jq, forge)"
	@echo ""
	@echo "PDP Tools:"
	@echo "  pdp-create-dataset - Create PDP dataset"
	@echo "  pdp-test-burn-fee  - Test PDP burn fee"
	@echo "  pdp-upgrade-contract - Upgrade PDP contract"
	@echo "  pdp-claim-owner     - Claim PDP contract ownership"
	@echo ""
	@echo "Development Workflow:"
	@echo "  ci               - Run CI pipeline (install, build, test, lint, coverage, size-check)"
	@echo "  release          - Run release-please"
	@echo "  release-create   - Create release with release-please"
	@echo "  release-tag      - Tag release with release-please"
	@echo ""
	@echo "Utilities:"
	@echo "  help             - Show this help message"
	@echo "  all              - Install, build, and test everything"
	@echo "  list-tools       - List available tools in packages"

.PHONY: list-tools
list-tools:
	@echo "Available tools across all packages:"
	@echo ""
	@for package in $(PACKAGES); do \
		if [ -d "packages/$$package/tools" ]; then \
			echo "$$package package tools:"; \
			ls -la packages/$$package/tools/*.sh 2>/dev/null | awk '{print "  " $$9}' | sed 's|packages/.*/tools/||' || echo "  (no tools found)"; \
			echo ""; \
		fi; \
	done

# =============================================================================
# PACKAGE-SPECIFIC TOOLS (delegation to individual package tools)
# =============================================================================

# PDP specific tools
.PHONY: pdp-create-dataset
pdp-create-dataset:
	@echo "Creating PDP dataset..."
	cd packages/pdp && ./tools/create_data_set.sh

.PHONY: pdp-test-burn-fee
pdp-test-burn-fee:
	@echo "Testing PDP burn fee..."
	cd packages/pdp && ./tools/testBurnFee.sh

.PHONY: pdp-upgrade-contract
pdp-upgrade-contract:
	@echo "Upgrading PDP contract..."
	cd packages/pdp && ./tools/upgrade-contract.sh

.PHONY: pdp-claim-owner
pdp-claim-owner:
	@echo "Claiming PDP ownership..."
	cd packages/pdp && ./tools/claim-owner.sh

# =============================================================================
# CODE GENERATION & COVERAGE
# =============================================================================

# Generated files for warm-storage
WARM_STORAGE_LAYOUT=packages/warm-storage/src/lib/FilecoinWarmStorageServiceLayout.sol
WARM_STORAGE_INTERNAL_LIB=packages/warm-storage/src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol
WARM_STORAGE_VIEW_CONTRACT=packages/warm-storage/src/FilecoinWarmStorageServiceStateView.sol
WARM_STORAGE_LIBRARY_JSON=out/FilecoinWarmStorageServiceStateLibrary.sol/FilecoinWarmStorageServiceStateLibrary.json

# Code generation targets
.PHONY: gen
gen: check-tools $(WARM_STORAGE_LAYOUT) $(WARM_STORAGE_INTERNAL_LIB) $(WARM_STORAGE_VIEW_CONTRACT)
	@echo "Code generation complete"

.PHONY: force-gen
force-gen: clean-gen gen
	@echo "Force regeneration complete"

.PHONY: clean-gen
clean-gen:
	@echo "Removing generated files..."
	@rm -f $(WARM_STORAGE_LAYOUT) $(WARM_STORAGE_INTERNAL_LIB) $(WARM_STORAGE_VIEW_CONTRACT)
	@rm -rf out/FilecoinWarmStorageServiceStateLibrary.sol
	@echo "Generated files removed"

# Storage layout generation
$(WARM_STORAGE_LAYOUT): packages/warm-storage/tools/generate_storage_layout.sh packages/warm-storage/src/FilecoinWarmStorageService.sol
	$^ | forge fmt -r - > $@

# JSON compilation for library
$(WARM_STORAGE_LIBRARY_JSON): packages/warm-storage/src/lib/FilecoinWarmStorageServiceStateLibrary.sol
	forge build --via-ir $^

# View contract generation
$(WARM_STORAGE_VIEW_CONTRACT): packages/warm-storage/tools/generate_view_contract.sh $(WARM_STORAGE_LIBRARY_JSON)
	$^ | forge fmt -r - > $@

# Internal library generation
%StateInternalLibrary.sol: %StateLibrary.sol
	sed -e 's/public/internal/g' -e 's/StateLibrary/StateInternalLibrary/g' $< | awk 'NR == 4 { print "// Code generated - DO NOT EDIT.\n// This file is a generated binding and any changes will be lost.\n// Generated with make $@\n"} {print}' | forge fmt -r - > $@

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

# Coverage targets
.PHONY: coverage
coverage:
	@echo "Running coverage with --ir-minimum (required due to stack depth issues)..."
	forge coverage --ir-minimum --report summary

.PHONY: coverage-lcov
coverage-lcov:
	@echo "Generating LCOV coverage report with --ir-minimum..."
	forge coverage --ir-minimum --report lcov

# Contract size check
.PHONY: contract-size-check
contract-size-check:
	@echo "Checking contract sizes..."
	bash packages/warm-storage/tools/check-contract-size.sh packages/

# =============================================================================
# DEVELOPMENT WORKFLOW
# =============================================================================

.PHONY: dev-setup
dev-setup: install
	@echo "Development environment setup complete!"

.PHONY: ci
ci: install build test lint
	@echo "CI pipeline completed successfully!"

.PHONY: pre-commit
pre-commit: format lint test
	@echo "Pre-commit checks completed!"

# =============================================================================
# RELEASE MANAGEMENT
# =============================================================================

.PHONY: release
release:
	@echo "Creating release..."
	npm run release

.PHONY: release-create
release-create:
	@echo "Creating release PR..."
	npm run release:create

.PHONY: release-tag
release-tag:
	@echo "Tagging release..."
	npm run release:tag

