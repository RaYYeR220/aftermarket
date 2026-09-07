# Aftermarket - contracts
#
# Two toolchains live side by side here and they are not interchangeable.
#
#   forge        stock Foundry. Runs the unit suite.
#   base-forge   Base's fork of Foundry, from https://github.com/base/base-anvil.
#                Hosts Base's Rust precompiles inside the EVM, which is the only
#                way to execute a B20 tokenized-equity token. `eth_getCode` on a
#                B20 address returns the single byte 0xef; stock forge tries to
#                execute it and halts with OpcodeNotFound. Everything in
#                test/fork therefore runs under base-forge.
#
# Install base-forge once with:
#   curl -L https://raw.githubusercontent.com/base/base-anvil/HEAD/foundryup/install | bash && base-foundryup
#
# The fork targets need BASE_RPC_URL pointing at a Base mainnet archive RPC. They
# skip with a message rather than failing when it is unset, so `make test-all` is
# safe in an environment that has no RPC.

SHELL := /bin/sh

FORGE      ?= forge
BASE_FORGE ?= base-forge

UNIT_TESTS := --no-match-path 'test/fork/*'
FORK_TESTS := --match-path 'test/fork/*'

# Written by test/fork/WeekendReplay.t.sol. It lands under deployments/ because
# that is the only path foundry.toml grants tests write access to, and the file
# is copied next to the test that produced it so it can be read as evidence.
TIMELINE_SRC := deployments/weekend-timeline.txt
TIMELINE_DST := test/fork/weekend-timeline.txt

.PHONY: all test test-fork test-all fmt fmt-check sizes snapshot clean help

all: test

## test: unit suite only, stock forge, no network access required
test:
	$(FORGE) test $(UNIT_TESTS) $(ARGS)

## test-fork: live Base mainnet fork suite, base-forge, needs BASE_RPC_URL
test-fork:
	@if [ -z "$(BASE_RPC_URL)" ]; then \
		echo "SKIP  test-fork: BASE_RPC_URL is not set."; \
		echo "      The fork suite reads live Base mainnet state (B20 precompiles,"; \
		echo "      Chainlink aggregators, Aerodrome pools) and cannot run offline."; \
		echo "      Set it and re-run, e.g.:"; \
		echo "        BASE_RPC_URL=https://mainnet.base.org make test-fork"; \
		exit 0; \
	fi; \
	command -v $(BASE_FORGE) >/dev/null 2>&1 || { \
		echo "ERROR test-fork: '$(BASE_FORGE)' not found on PATH."; \
		echo "      B20 tokens are Rust precompiles, not EVM contracts; stock forge"; \
		echo "      halts with OpcodeNotFound on the first token call. Install with:"; \
		echo "        curl -L https://raw.githubusercontent.com/base/base-anvil/HEAD/foundryup/install | bash"; \
		echo "        base-foundryup"; \
		exit 1; \
	}; \
	$(BASE_FORGE) test $(FORK_TESTS) $(ARGS); \
	status=$$?; \
	if [ -f "$(TIMELINE_SRC)" ]; then cp "$(TIMELINE_SRC)" "$(TIMELINE_DST)"; fi; \
	exit $$status

## test-all: unit suite, then the fork suite
test-all: test test-fork

## fmt: format every Solidity file in the project
fmt:
	$(FORGE) fmt

## fmt-check: fail if anything is unformatted
fmt-check:
	$(FORGE) fmt --check

## sizes: report deployed bytecode size against the EIP-170 limit
sizes:
	$(FORGE) build --sizes

## snapshot: gas snapshot of the unit suite (fork gas is not reproducible)
snapshot:
	$(FORGE) snapshot $(UNIT_TESTS) $(ARGS)

## clean: drop build artifacts
clean:
	$(FORGE) clean

## help: list the targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
