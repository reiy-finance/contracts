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

# ---- 1. init_treasury<USDC> ----
echo "Step 1: init_treasury<${USDC_TYPE}> ..."
TREASURY_OUTPUT=$(
  sui client ptb \
    --move-call "${REIY_PACKAGE_ID}::treasury::init_treasury<${USDC_TYPE}>" \
      "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}" \
    --json 2>&1
)
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

# ---- 2. set_numeraire<USDC> ----
echo ""
echo "Step 2: set_numeraire<${USDC_TYPE}> ..."
sui client ptb \
  --move-call "${REIY_PACKAGE_ID}::config::set_numeraire<${USDC_TYPE}>" \
    "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
  --gas-budget "${GAS_BUDGET}"

# ---- 3. add_numeraire_pool per buy token that needs normalization ----
# DEEPBOOK_SUI_USDC_POOL maps SUI -> USDC numeraire direction.
# Pattern: add_numeraire_pool<Token>(config, pool_id, cap)
if [[ -n "${DEEPBOOK_SUI_USDC_POOL:-}" ]]; then
  echo ""
  echo "Step 3: add_numeraire_pool for SUI -> USDC pool: $DEEPBOOK_SUI_USDC_POOL ..."
  sui client ptb \
    --move-call "${REIY_PACKAGE_ID}::config::add_numeraire_pool<0x2::sui::SUI>" \
      "@${GLOBAL_CONFIG_ID}" "@${DEEPBOOK_SUI_USDC_POOL}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
else
  echo "Step 3: DEEPBOOK_SUI_USDC_POOL not set — skipping"
fi

# ---- 4. add_supported_pairs ----
echo ""
echo "Step 4: add_supported_pairs ..."
if [[ -z "${SUPPORTED_PAIRS:-}" ]]; then
  echo "SUPPORTED_PAIRS not set — skipping"
else
  for PAIR in $SUPPORTED_PAIRS; do
    SELL=$(echo "$PAIR" | cut -d: -f1,2,3)   # e.g. 0x2::sui::SUI
    BUY=$(echo "$PAIR"  | rev | cut -d: -f1,2,3 | rev)  # trailing after last delim set
    # Re-split by the literal ":" separator between the two types
    SELL=$(echo "$PAIR" | python3 -c "import sys; p=sys.stdin.read().strip().split(':'); print(':'.join(p[:3]))")
    BUY=$(echo "$PAIR"  | python3 -c "import sys; p=sys.stdin.read().strip().split(':'); print(':'.join(p[3:]))")
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
