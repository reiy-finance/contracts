#!/usr/bin/env bash
# Post-deploy protocol setup.
# Usage: setup.sh <env_file>
set -euo pipefail

ENV_FILE=${1:-.env.testnet}
source "$ENV_FILE"

required_vars=(
  REIY_PACKAGE_ID GLOBAL_CONFIG_ID ADMIN_CAP_ID
  USDC_TYPE SUI_TYPE GAS_BUDGET
)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set in $ENV_FILE" >&2
    exit 1
  fi
done

set_env_var() {
  local key=$1
  local value=$2
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

run_ptb() {
  local attempt=1
  local output
  local rc
  local attempts=${SUI_PTB_RETRY_ATTEMPTS:-6}
  local delay=${SUI_PTB_RETRY_DELAY:-3}
  local settle_delay=${SUI_PTB_SETTLE_DELAY:-1}

  while true; do
    output=$(sui client ptb "$@" 2>&1)
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      if [[ "$settle_delay" != "0" ]]; then
        sleep "$settle_delay"
      fi
      printf "%s\n" "$output"
      return 0
    fi

    if [[ "$output" == *"already locked by a different transaction"* && "$attempt" -lt "$attempts" ]]; then
      echo "Gas object locked; retrying in ${delay}s (${attempt}/${attempts})..." >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi

    printf "%s\n" "$output"
    return "$rc"
  done
}

echo "=== REIY Setup ==="
echo "Package : $REIY_PACKAGE_ID"
echo "Config  : $GLOBAL_CONFIG_ID"
echo "AdminCap: $ADMIN_CAP_ID"
echo ""

STAKE_TYPE=${STAKE_TYPE:-$SUI_TYPE}
echo "Stake   : $STAKE_TYPE"
echo ""

echo "Step 1: set_numeraire<${USDC_TYPE}> ..."
run_ptb \
  --move-call "${REIY_PACKAGE_ID}::config::set_numeraire<${USDC_TYPE}>" \
    "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
  --gas-budget "${GAS_BUDGET}"

echo ""
REGISTRY_ID=${SOLVER_REGISTRY_ID:-}
REGISTRY_CREATED=0
if [[ -n "$REGISTRY_ID" ]]; then
  echo "Step 2: use SolverRegistry ${REGISTRY_ID}"
else
  echo "Step 2: init_registry<${STAKE_TYPE}> ..."
  REGISTRY_OUTPUT=$(
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::solver_registry::init_registry<${STAKE_TYPE}>" \
        "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}" \
      --json 2>&1
  ) || {
    echo "$REGISTRY_OUTPUT" >&2
    exit 1
  }
  echo "$REGISTRY_OUTPUT" | tee /tmp/reiy_registry_deploy.json

  REGISTRY_ID=$(echo "$REGISTRY_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.type == "created")
    | select(.objectType | test("SolverRegistry"))
    | .objectId
  ' | head -1)

  if [[ -z "$REGISTRY_ID" ]]; then
    echo "ERROR: could not extract SolverRegistry ID" >&2
    exit 1
  fi
  echo "SolverRegistry: $REGISTRY_ID"
  set_env_var SOLVER_REGISTRY_ID "$REGISTRY_ID"
  REGISTRY_CREATED=1
fi

if [[ "$REGISTRY_CREATED" -eq 1 || "${REBIND_CANONICAL_IDS:-0}" == "1" ]]; then
  run_ptb \
    --move-call "${REIY_PACKAGE_ID}::config::set_solver_registry_id" \
      "@${GLOBAL_CONFIG_ID}" "@${REGISTRY_ID}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
else
  echo "Step 2b: registry binding already recorded"
fi

echo ""
TREASURY_ID=${PROTOCOL_TREASURY_ID:-}
TREASURY_CREATED=0
if [[ -n "$TREASURY_ID" ]]; then
  echo "Step 3: use ProtocolTreasury ${TREASURY_ID}"
else
  echo "Step 3: init_treasury<${USDC_TYPE},${STAKE_TYPE}> ..."
  TREASURY_OUTPUT=$(
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::treasury::init_treasury<${USDC_TYPE},${STAKE_TYPE}>" \
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
  set_env_var PROTOCOL_TREASURY_ID "$TREASURY_ID"
  TREASURY_CREATED=1
fi

if [[ "$TREASURY_CREATED" -eq 1 || "${REBIND_CANONICAL_IDS:-0}" == "1" ]]; then
  run_ptb \
    --move-call "${REIY_PACKAGE_ID}::config::set_protocol_treasury_id" \
      "@${GLOBAL_CONFIG_ID}" "@${TREASURY_ID}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
else
  echo "Step 3b: treasury binding already recorded"
fi

add_numeraire_pool_if_set() {
  local token_label=$1
  local token_type=$2
  local pool_id=$3

  if [[ -z "$token_type" || -z "$pool_id" ]]; then
    echo "  Skipping ${token_label}: token type or pool id not set"
    return
  fi

  echo "  Adding numeraire pool for ${token_label}: ${pool_id}"
  run_ptb \
    --move-call "${REIY_PACKAGE_ID}::config::add_numeraire_pool<${token_type}>" \
      "@${GLOBAL_CONFIG_ID}" "@${pool_id}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
}

echo ""
echo "Step 4: add_numeraire_pool ..."
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

# ---- 5. add_supported_pairs ----
echo ""
echo "Step 5: add_supported_pairs ..."
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
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::config::add_supported_pair<${SELL},${BUY}>" \
        "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}"
  done
fi

# ---- 6. (mainnet only) transfer AdminCap to multisig ----
if [[ -n "${MULTISIG_ADDRESS:-}" ]]; then
  echo ""
  echo "Step 6: Transferring AdminCap to multisig ${MULTISIG_ADDRESS} ..."
  run_ptb \
    --transfer-objects "[@${ADMIN_CAP_ID}]" "@${MULTISIG_ADDRESS}" \
    --gas-budget "${GAS_BUDGET}"
  echo "✓ AdminCap transferred — you can no longer call setup again without multisig co-sign"
else
  echo "Step 6: MULTISIG_ADDRESS not set — AdminCap stays with deployer"
fi

echo ""
echo "=== Setup complete ==="
echo "SOLVER_REGISTRY_ID = $REGISTRY_ID"
echo "PROTOCOL_TREASURY_ID = $TREASURY_ID"
