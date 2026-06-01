# =============================================================================
# REIY Mainnet Move Contracts — Build, Test, Deploy
# =============================================================================
# Usage:
#   make build              — compile package
#   make test               — run full test suite
#   make deploy-testnet     — publish to testnet and save IDs to .env.testnet
#   make setup-testnet      — init registry/treasury + supported pairs on testnet
#   make verify-testnet     — check deployed objects exist with correct types
#   make deploy-mainnet     — publish to mainnet (requires confirmation)
#   make setup-mainnet      — post-deploy mainnet setup
#   make verify-mainnet     — verify mainnet objects
#
# Before first run:
#   cp .env.testnet.example .env.testnet   # then fill in pool IDs etc.
#   cp .env.mainnet.example .env.mainnet
# =============================================================================

SHELL        := /bin/bash
PACKAGE_PATH  := .
PKG_NAME      := reiy
SCRIPTS       := $(CURDIR)/scripts

# Defaults — override from env or command line
GAS_TESTNET   ?= 500000000
GAS_MAINNET   ?= 500000000
PUBLISH_FLAGS ?= --skip-dependency-verification

# Env files (created from examples by the developer)
ENV_TESTNET   := .env.testnet
ENV_MAINNET   := .env.mainnet

# Temporary files for publish JSON output
TMP_TESTNET   := /tmp/reiy_publish_testnet.json
TMP_MAINNET   := /tmp/reiy_publish_mainnet.json

# ─── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo ""
	@echo "REIY Contract Makefile"
	@echo "────────────────────────────────────────────────────"
	@echo "  make build              compile (testnet env)"
	@echo "  make build-mainnet      compile (mainnet env)"
	@echo "  make test               run full Move test suite"
	@echo "  make lint               build with linter warnings visible"
	@echo ""
	@echo "  make deploy-testnet     publish to testnet → saves IDs to .env.testnet"
	@echo "  make setup-testnet      init registry/treasury + pairs + numeraire on testnet"
	@echo "  make verify-testnet     verify deployed objects on testnet"
	@echo ""
	@echo "  make deploy-mainnet     publish to mainnet (prompts for confirmation)"
	@echo "  make setup-mainnet      post-deploy mainnet setup"
	@echo "  make verify-mainnet     verify deployed objects on mainnet"
	@echo ""
	@echo "  make clean              remove build artifacts"
	@echo "  make mint-testnet       mint test coins  (TOKEN=WUSDC AMOUNT=1000000000000)"
	@echo ""

# ─── Build & Test ────────────────────────────────────────────────────────────

.PHONY: build
build:
	sui move build --build-env testnet

.PHONY: build-mainnet
build-mainnet:
	sui move build --build-env mainnet

.PHONY: test
test:
	sui move test

.PHONY: lint
lint:
	sui move build 2>&1

.PHONY: clean
clean:
	rm -rf build/

# ─── Gas benchmarks ──────────────────────────────────────────────────────────

GAS_LIMIT ?= 50000000000000

# Gas report: CSV columns are  test_name, wall_time_ns, gas_remaining
# Gas consumed = GAS_LIMIT - gas_remaining
.PHONY: bench
bench:
	@echo ""
	@printf "%-56s %12s  %12s\n" "Test" "Gas consumed" "Wall (ms)"
	@printf '%0.s─' {1..82}; echo ""
	@sui move test bench_ -s csv --gas-limit $(GAS_LIMIT) 2>&1 \
	  | grep "^reiy::gas_benchmarks::" \
	  | awk -F',' -v limit=$(GAS_LIMIT) '{ \
	      name = $$1; sub(/.*::/, "", name); \
	      wall_ms = $$2 / 1000000; \
	      consumed = limit - $$3; \
	      printf "%-56s %12d  %9.3f ms\n", name, consumed, wall_ms; \
	    }' \
	  | sort -k2 -n
	@echo ""

.PHONY: bench-csv
bench-csv:
	@sui move test bench_ -s csv --gas-limit $(GAS_LIMIT) 2>&1 \
	  | grep "^reiy::gas_benchmarks::" \
	  | awk -F',' -v limit=$(GAS_LIMIT) 'BEGIN{print "test,gas_consumed,wall_ms"} \
	    { name=$$1; sub(/.*::/,"",name); print name "," limit-$$3 "," $$2/1000000 }' \
	  > gas_report.csv
	@echo "Saved to gas_report.csv"

# CI regression: fail if any bench exceeds 20M gas
.PHONY: bench-ci
bench-ci:
	sui move test bench_ --gas-limit 20000000

# ─── Test-coin utilities (testnet only) ──────────────────────────────────────

# Mint more WUSDC test tokens to the active address (needs TreasuryCap).
# Usage: make mint-testnet TOKEN=WUSDC AMOUNT=1000000000000
.PHONY: mint-testnet
mint-testnet: _env-testnet-check
	@source $(ENV_TESTNET) && \
	  TOKEN=$${TOKEN:-WUSDC} && \
	  AMOUNT=$${AMOUNT:-1000000000000} && \
	  CAP_VAR=$${TOKEN}_TREASURY_CAP && \
	  CAP=$${!CAP_VAR} && \
	  TYPE_VAR=$${TOKEN}_TYPE && \
	  COIN_TYPE=$${!TYPE_VAR} && \
	  if [ -z "$$CAP" ] || [ -z "$$COIN_TYPE" ]; then \
	    echo "ERROR: $${TOKEN}_TREASURY_CAP or $${TOKEN}_TYPE not set in $(ENV_TESTNET)"; exit 1; \
	  fi && \
	  echo "Minting $$AMOUNT of $$COIN_TYPE ..." && \
	  DEST=$$(sui client active-address) && \
	  sui client ptb \
	    --move-call "0x2::coin::mint_and_transfer<$${COIN_TYPE}>" \
	      "@$${CAP}" "$$AMOUNT" "@$$DEST" \
	    --gas-budget $(GAS_TESTNET)

# ─── Testnet ─────────────────────────────────────────────────────────────────

.PHONY: deploy-testnet
deploy-testnet: build _env-testnet-check
	@echo "Switching to testnet..."
	@sui client switch --env testnet
	@rm -f Published.toml
	@echo "Publishing REIY to testnet..."
	sui client publish $(PACKAGE_PATH) \
		--gas-budget $(GAS_TESTNET) \
		$(PUBLISH_FLAGS) \
		--json > $(TMP_TESTNET)
	@echo "Publish output: $(TMP_TESTNET)"
	@$(SCRIPTS)/extract_ids.sh $(TMP_TESTNET) $(ENV_TESTNET) $(PKG_NAME)
	@echo ""
	@echo "Testnet deploy complete. Next: make setup-testnet"

.PHONY: setup-testnet
setup-testnet: _env-testnet-check
	@echo "Switching to testnet..."
	@sui client switch --env testnet
	@$(SCRIPTS)/setup.sh $(ENV_TESTNET)

.PHONY: verify-testnet
verify-testnet: _env-testnet-check
	@sui client switch --env testnet
	@$(SCRIPTS)/verify.sh $(ENV_TESTNET)

# ─── Mainnet ─────────────────────────────────────────────────────────────────

.PHONY: deploy-mainnet
deploy-mainnet: build-mainnet _env-mainnet-check _confirm-mainnet
	@echo "Switching to mainnet..."
	@sui client switch --env mainnet
	@rm -f Published.toml
	@echo "Publishing REIY to MAINNET..."
	sui client publish $(PACKAGE_PATH) \
		--gas-budget $(GAS_MAINNET) \
		$(PUBLISH_FLAGS) \
		--json > $(TMP_MAINNET)
	@echo "Publish output: $(TMP_MAINNET)"
	@$(SCRIPTS)/extract_ids.sh $(TMP_MAINNET) $(ENV_MAINNET) $(PKG_NAME)
	@echo ""
	@echo "Mainnet deploy complete. Next: make setup-mainnet"

.PHONY: setup-mainnet
setup-mainnet: _env-mainnet-check _confirm-mainnet
	@echo "Switching to mainnet..."
	@sui client switch --env mainnet
	@$(SCRIPTS)/setup.sh $(ENV_MAINNET)

.PHONY: verify-mainnet
verify-mainnet: _env-mainnet-check
	@sui client switch --env mainnet
	@$(SCRIPTS)/verify.sh $(ENV_MAINNET)

# ─── Internal guards ─────────────────────────────────────────────────────────

.PHONY: _env-testnet-check
_env-testnet-check:
	@if [ ! -f "$(ENV_TESTNET)" ]; then \
	  echo ""; \
	  echo "ERROR: $(ENV_TESTNET) not found."; \
	  echo "Run: cp .env.testnet.example .env.testnet  then fill in pool IDs."; \
	  echo ""; \
	  exit 1; \
	fi

.PHONY: _env-mainnet-check
_env-mainnet-check:
	@if [ ! -f "$(ENV_MAINNET)" ]; then \
	  echo ""; \
	  echo "ERROR: $(ENV_MAINNET) not found."; \
	  echo "Run: cp .env.mainnet.example .env.mainnet  then fill in values."; \
	  echo ""; \
	  exit 1; \
	fi

.PHONY: _confirm-mainnet
_confirm-mainnet:
	@echo ""
	@echo "  ⚠  WARNING: You are about to interact with MAINNET."
	@echo "     Active address: $$(sui client active-address)"
	@echo "     Active env    : $$(sui client active-env)"
	@echo ""
	@read -p "  Type YES to continue: " CONFIRM && \
	  [ "$$CONFIRM" = "YES" ] || (echo "Aborted."; exit 1)
	@echo ""
