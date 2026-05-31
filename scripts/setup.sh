#!/usr/bin/env bash
# Post-deploy setup: init_treasury, add_supported_pairs, add_numeraire_pool.
# All calls go through `sui client ptb` (no move test_only paths).
# Usage: setup.sh <env_file>
set -euo pipefail

ENV_FILE=${1:-.env.testnet}
source "$ENV_FILE"

# --- guard: make sure required vars are set ---
required_vars=(
  REIY_PACKAGE_ID GLOBAL_CONFIG_ID ADMIN_CAP_ID
  USDC_TYPE GAS_BUDGET
)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set in $ENV_FILE" >&2
    exit 1
  fi
done

echo "=== REIY Setup ==="
echo "Package : $REIY_PACKAGE_ID"
echo "Config  : $GLOBAL_CONFIG_ID"
echo "AdminCap: $ADMIN_CAP_ID"
echo ""

# ---- 1. set_numeraire<USDC> ----
echo "Step 1: set_numeraire<${USDC_TYPE}> ..."
sui client ptb \
  --move-call "${REIY_PACKAGE_ID}::config::set_numeraire<${USDC_TYPE}>" \
    "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
  --gas-budget "${GAS_BUDGET}"

# ---- 2. init_treasury<USDC> ----
echo ""
echo "Step 2: init_treasury<${USDC_TYPE}> ..."
TREASURY_OUTPUT=$(
  sui client ptb \
    --move-call "${REIY_PACKAGE_ID}::treasury::init_treasury<${USDC_TYPE}>" \
      "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}" \
    --json 2>&1
) || {
  echo "$TREASURY_OUTPUT" >&2
  exit 1
}
echo "$TREASURY_OUTPUT" | tee /tmp/reiy_treasury_deploy.json

TREASURY_ID=$(echo "$TREASURY_OUTPUT" | jq -r '
  .objectChanges[]
  | select(.type == "created")
  | select(.objectType | test("ProtocolTreasury"))
  | .objectId
' | head -1)

if [[ -z "$TREASURY_ID" ]]; then
  echo "ERROR: could not extract ProtocolTreasury ID" >&2
  exit 1
fi
echo "ProtocolTreasury: $TREASURY_ID"

# save to env file
if grep -q "^PROTOCOL_TREASURY_ID=" "$ENV_FILE"; then
  sed -i.bak "s|^PROTOCOL_TREASURY_ID=.*|PROTOCOL_TREASURY_ID=${TREASURY_ID}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
else
  echo "PROTOCOL_TREASURY_ID=${TREASURY_ID}" >> "$ENV_FILE"
fi

# ---- 3. add_numeraire_pool per token that needs normalization ----
# Pattern: add_numeraire_pool<Token>(config, pool_id, cap)
add_numeraire_pool_if_set() {
  local token_label=$1
  local token_type=$2
  local pool_id=$3

  if [[ -z "$token_type" || -z "$pool_id" ]]; then
    echo "  Skipping ${token_label}: token type or pool id not set"
    return
  fi

  echo "  Adding numeraire pool for ${token_label}: ${pool_id}"
  sui client ptb \
    --move-call "${REIY_PACKAGE_ID}::config::add_numeraire_pool<${token_type}>" \
      "@${GLOBAL_CONFIG_ID}" "@${pool_id}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
}

echo ""
echo "Step 3: add_numeraire_pool ..."
if [[ -n "${NUMERAIRE_POOLS:-}" ]]; then
  for ENTRY in $NUMERAIRE_POOLS; do
    if [[ "$ENTRY" == *"|"* ]]; then
      TOKEN_TYPE=${ENTRY%%|*}
      POOL_ID=${ENTRY#*|}
    elif [[ "$ENTRY" == *":0x"* ]]; then
      TOKEN_TYPE=${ENTRY%%:0x*}
      POOL_ID=0x${ENTRY#*:0x}
    else
      echo "ERROR: unsupported numeraire pool format: $ENTRY" >&2
      echo "Use TOKEN_TYPE|POOL_ID" >&2
      exit 1
    fi

    add_numeraire_pool_if_set "$TOKEN_TYPE" "$TOKEN_TYPE" "$POOL_ID"
  done
else
  add_numeraire_pool_if_set "WSUI -> WUSDC" "${WSUI_TYPE:-}" "${DEEPBOOK_WSUI_WUSDC_POOL:-}"
  add_numeraire_pool_if_set "WDEEP -> WUSDC" "${WDEEP_TYPE:-}" "${DEEPBOOK_WDEEP_WUSDC_POOL:-}"
fi

# ---- 4. add_supported_pairs ----
echo ""
echo "Step 4: add_supported_pairs ..."
if [[ -z "${SUPPORTED_PAIRS:-}" ]]; then
  echo "SUPPORTED_PAIRS not set — skipping"
else
  for PAIR in $SUPPORTED_PAIRS; do
    if [[ "$PAIR" == *"|"* ]]; then
      SELL=${PAIR%%|*}
      BUY=${PAIR#*|}
    elif [[ "$PAIR" == *":0x"* ]]; then
      SELL=${PAIR%%:0x*}
      BUY=0x${PAIR#*:0x}
    else
      echo "ERROR: unsupported pair format: $PAIR" >&2
      echo "Use SELL_TYPE:BUY_TYPE or SELL_TYPE|BUY_TYPE" >&2
      exit 1
    fi

    if [[ -z "$SELL" || -z "$BUY" || "$SELL" == "$BUY" ]]; then
      echo "ERROR: could not parse supported pair: $PAIR" >&2
      exit 1
    fi

    echo "  Adding pair: ${SELL} -> ${BUY}"
    sui client ptb \
      --move-call "${REIY_PACKAGE_ID}::config::add_supported_pair<${SELL},${BUY}>" \
        "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}"
  done
fi

# ---- 5. (mainnet only) transfer AdminCap to multisig ----
if [[ -n "${MULTISIG_ADDRESS:-}" ]]; then
  echo ""
  echo "Step 5: Transferring AdminCap to multisig ${MULTISIG_ADDRESS} ..."
  sui client ptb \
    --transfer-objects "[@${ADMIN_CAP_ID}]" "@${MULTISIG_ADDRESS}" \
    --gas-budget "${GAS_BUDGET}"
  echo "✓ AdminCap transferred — you can no longer call setup again without multisig co-sign"
else
  echo "Step 5: MULTISIG_ADDRESS not set — AdminCap stays with deployer"
fi

echo ""
echo "=== Setup complete ==="
echo "PROTOCOL_TREASURY_ID = $TREASURY_ID"
