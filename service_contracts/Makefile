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
VIEW_MODULE=src/modules/FWSSViewModule.sol
FWSS_INTERFACE=src/interfaces/IFilecoinWarmStorageService.sol
# FWSS runs facets behind the ERC-8167 dispatcher, so its ABI comes from josuke abi, not one contract's artifact
FWSS_ABI=abi/FilecoinWarmStorageService.abi.json
# Tests and scripts consume the FWSS interface. When it is stale they may not compile, which must not block
# regenerating it, so builds toward it skip them.
SKIP_INTERFACE_CONSUMERS := ["test/**","script/**"]

# wjmelements/evm assembles the ERC-8167 dispatcher. CI, local tests and josuke should share this revision.
EVM_REPO := https://github.com/wjmelements/evm.git
EVM_REVISION := 98409233b4ed9fb79efa013fe17ad42b155adf03
EVM_DIR ?= $(HOME)/.cache/wjmelements-evm/$(EVM_REVISION)
# Install beside forge, which is already on PATH
EVM_INSTALL_DIR ?= $(patsubst %/,%,$(dir $(shell command -v forge)))

# josuke deploys the modules and migrations and keeps josuke.json; its ledger format still changes
JOSUKE_REPO := https://github.com/wjmelements/josuke.git
JOSUKE_REVISION := 7e59ebb8f24bd256dd89cefd0a3f686af49a491c

# Build target
.PHONY: build
build:
	forge build --via-ir

# Build the pinned evm assembler once per revision
.PHONY: install-evm
install-evm: $(EVM_DIR)/bin/evm
	@test -n "$(EVM_INSTALL_DIR)" || (echo 'forge is not on PATH; set EVM_INSTALL_DIR'; exit 1)
	install $< $(EVM_INSTALL_DIR)/evm

$(EVM_DIR)/bin/evm:
	git clone --depth 1 --revision $(EVM_REVISION) --recurse-submodules --shallow-submodules --no-tags $(EVM_REPO) $(EVM_DIR)
	$(MAKE) -C $(EVM_DIR) bin/evm

# Install the pinned josuke CLI with uv
.PHONY: install-josuke
install-josuke:
	uv tool install --force "josuke @ git+$(JOSUKE_REPO)@$(JOSUKE_REVISION)"

# Compile the upstream dispatcher unchanged. No Solidity wrapper or bytecode padding.
# Only tests and the dispatcher deployment use these artifacts; FWSS pins the dispatcher code hash.
.PHONY: erc8167
erc8167:
	@command -v evm >/dev/null || (echo 'Missing the evm assembler; run make install-evm'; exit 1)
	$(MAKE) -C lib/erc8167 out/Proxy.evm/Proxy.json out/Implementation.evm/Implementation.json

# Storage layout generation
$(LAYOUT): tools/generate_storage_layout.sh src/storage/FWSSStorage.sol
	bash -o pipefail -c 'bash $^ | forge fmt -r - > "$@.tmp"'
	mv $@.tmp $@

# View module generation (sload in place of the library's extsload)
$(VIEW_MODULE): tools/generate_view_module.sh src/lib/FilecoinWarmStorageServiceStateLibrary.sol
	bash -o pipefail -c '$^ | forge fmt -r - > "$@.tmp"'
	mv $@.tmp $@

# FWSS interface generation from the FWSS ABI
$(FWSS_INTERFACE): export FOUNDRY_SKIP = $(SKIP_INTERFACE_CONSUMERS)
$(FWSS_INTERFACE): tools/generate_fwss_interface.sh tools/generate_interface.jq $(FWSS_ABI)
	@! grep -l IFilecoinWarmStorageService src/modules/*.sol || (echo 'Modules must not import the interface generated from their ABI'; exit 1)
	bash -o pipefail -c '$< $(FWSS_ABI) | forge fmt -r - > "$@.tmp"'
	mv $@.tmp $@

# Internal library generation (simple sed transform)
%StateInternalLibrary.sol: %StateLibrary.sol
	sed -e 's/public/internal/g' -e 's/StateLibrary/StateInternalLibrary/g' $< | awk 'NR == 4 { print "// Code generated - DO NOT EDIT.\n// This file is a generated binding and any changes will be lost.\n// Generated with make $@\n"} {print}' | forge fmt -r - > $@

# Main code generation target with proper dependencies
.PHONY: gen
gen: check-tools $(LAYOUT) $(INTERNAL_LIB) $(VIEW_MODULE) $(FWSS_INTERFACE)
	@echo "Code generation complete"

# Force regeneration - useful when things are broken
.PHONY: force-gen
force-gen: clean-gen
	$(MAKE) gen
	@echo "Force regeneration complete"

# Clean generated files only
.PHONY: clean-gen
clean-gen:
	@echo "Removing generated files..."
	@rm -f $(LAYOUT) $(INTERNAL_LIB) $(VIEW_MODULE) $(FWSS_INTERFACE)
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
test: erc8167
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
coverage: erc8167
	@echo "Running coverage with --ir-minimum (required due to stack depth issues)..."
	forge coverage --ir-minimum --report summary

# Coverage with LCOV report (for CI)
.PHONY: coverage-lcov
coverage-lcov: erc8167
	@echo "Generating LCOV coverage report with --ir-minimum..."
	forge coverage --ir-minimum --report lcov

.PHONY: contract-size-check
contract-size-check:
	@echo "Checking deployable contract sizes..."
	bash tools/check-contract-size.sh --check

# Offline josuke ledger check: schema, facetSrc resolution, selector collisions, EIP-170 sizes and facet storage
# against every deployment josuke.json records, including the legacy v1.4.0 monolith. Pass JOSUKE_CHECK_ARGS="--format markdown" for $GITHUB_STEP_SUMMARY.
.PHONY: check-josuke
check-josuke:
	@command -v josuke >/dev/null || (echo 'Missing josuke; run make install-josuke'; exit 1)
	@command -v evm >/dev/null || (echo 'Missing the evm assembler; run make install-evm'; exit 1)
	@josuke check $(JOSUKE_CHECK_ARGS)

# ABI Management

# Core contracts we publish ABIs for.
# Contract ABIs extracted from build artifacts. update-abi gets FWSS's from josuke.
ABI_CONTRACTS := \
	IFilecoinServiceMetadata \
	FilecoinWarmStorageServiceStateLibrary \
	FilecoinPayV1 \
	PDPVerifier \
	ProviderIdSet \
	ServiceProviderRegistry \
	ServiceProviderRegistryStorage \
	SessionKeyRegistry \
	Errors

# Directory for ABIs
abi:
	@mkdir -p abi

# Update ABIs. FWSS runs facets behind the ERC-8167 dispatcher, so josuke merges its ABI from the facets josuke.json
# lists. The FWSS interface is generated from that ABI and the other contracts compile against it, so it comes first.
.PHONY: update-abi
update-abi: | abi
	@command -v josuke >/dev/null || (echo 'Missing josuke'; exit 1)
	FOUNDRY_SKIP='$(SKIP_INTERFACE_CONSUMERS)' bash -o pipefail -c 'josuke abi $$(jq -r ".[0].address" josuke.json) | jq . > "$(FWSS_ABI).tmp"'
	mv $(FWSS_ABI).tmp $(FWSS_ABI)
	$(MAKE) $(FWSS_INTERFACE)
	forge build --via-ir
	@set -e; for contract in $(ABI_CONTRACTS); do \
		artifact="out/$$contract.sol/$$contract.json"; \
		echo "Extracting ABI for $$contract..."; \
		jq '.abi' "$$artifact" > "abi/$$contract.abi.json"; \
	done

# Clean just the ABIs
.PHONY: clean-abi
clean-abi:
	@rm -f abi/*.abi.json

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  install    - Install dependencies (forge and npm)"
	@echo "  install-evm - Build the pinned evm assembler and install it beside forge"
	@echo "  install-josuke - Install the pinned josuke CLI with uv"
	@echo "  build      - Build contracts"
	@echo "  test       - Run tests"
	@echo "  clean      - Clean build artifacts"
	@echo "  fmt        - Format code"
	@echo "  fmt-check  - Check code formatting"
	@echo "  coverage   - Generate test coverage summary (uses --ir-minimum)"
	@echo "  coverage-lcov - Generate LCOV coverage report for CI"
	@echo ""
	@echo "Code generation targets:"
	@echo "  gen        - Generate code (layout, internal lib, view module)"
	@echo "  force-gen  - Clean and regenerate all files (use when broken)"
	@echo "  clean-gen  - Remove all generated files"
	@echo ""
	@echo "Validation targets:"
	@echo "  check-josuke - Check josuke.json and the facets it resolves offline (needs josuke and evm)"
	@echo "  contract-size-check - Check deployable contracts against size and headroom policy"
	@echo ""
	@echo "  help       - Show this help message"
	@echo ""
	@echo "ABI management targets:"
	@echo "  update-abi - Update checked-in ABIs in abi/ directory from an incremental build"
	@echo "  clean-abi  - Remove all ABI files"
	@echo ""
	@echo "Full cleanup:"
	@echo "  clean-all  - Remove all artifacts (build, generated, ABIs)"
