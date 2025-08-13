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

# Build target
.PHONY: build
build:
	forge build --via-ir

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
.PHONY: coverage
coverage:
	forge coverage --via-ir

.PHONY: contract-size-check
contract-size-check:
	@echo "Checking contract sizes..."
	bash tools/check-contract-size.sh src/

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
	@echo "  coverage   - Generate test coverage"
	@echo "  help       - Show this help message"
	@echo "  contract-size-check - Check contract sizes against EIP-170 and EIP-3860 limits"

# Extract just the ABI arrays into abi/ContractName.abi.json
.PHONY: extract-abis
extract-abis:
	mkdir -p abi
	@find out -type f -name '*.json' | while read file; do \
	  name=$$(basename "$${file%.*}"); \
	  jq '.abi' "$${file}" > "abi/$${name}.abi.json"; \
	done
