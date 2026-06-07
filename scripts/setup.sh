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

hex_to_u8_array() {
  local hex=${1#0x}
  hex=${hex#0X}

  if [[ "${#hex}" -ne 64 ]]; then
    echo "ERROR: COORDINATOR_PUBKEY must be a 32-byte hex string" >&2
    exit 1
  fi

  local bytes=()
  local i
  for ((i = 0; i < ${#hex}; i += 2)); do
    bytes+=("$((16#${hex:i:2}))")
  done

  local IFS=,
  printf '[%s]' "${bytes[*]}"
}

decode_public_key_hex() {
  local encoded=$1
  local hex
  hex=$(
    (
      printf "%s" "$encoded" | base64 --decode 2>/dev/null \
        || printf "%s" "$encoded" | base64 -D 2>/dev/null
    ) | od -An -tx1 -v | tr -d ' \n'
  )

  if [[ "${#hex}" -eq 66 ]]; then
    hex=${hex:2}
  fi

  if [[ "${#hex}" -ne 64 ]]; then
    echo "ERROR: could not decode a 32-byte Ed25519 public key from Sui keytool output" >&2
    exit 1
  fi

  printf "%s" "$hex"
}

derive_active_coordinator_pubkey() {
  local active
  active=$(sui client active-address)

  local encoded
  encoded=$(
    sui keytool list --json \
      | jq -r --arg active "$active" '
          .[]
          | select(.suiAddress == $active)
          | select(.keyScheme == "ed25519")
          | .publicBase64Key
        ' \
      | head -1
  )

  if [[ -z "$encoded" || "$encoded" == "null" ]]; then
    echo "ERROR: COORDINATOR_PUBKEY is not set and active Sui CLI key is not Ed25519" >&2
    exit 1
  fi

  decode_public_key_hex "$encoded"
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
FEE_VAULT_ID=${FEE_VAULT_ID:-}
FEE_VAULT_CREATED=0
if [[ -n "$FEE_VAULT_ID" ]]; then
  echo "Step 3: use FeeVault ${FEE_VAULT_ID}"
else
  echo "Step 3: init_fee_vault<${USDC_TYPE}> ..."
  FEE_VAULT_OUTPUT=$(
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::fee_vault::init_fee_vault<${USDC_TYPE}>" \
        "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}" \
      --json 2>&1
  ) || {
    echo "$FEE_VAULT_OUTPUT" >&2
    exit 1
  }
  echo "$FEE_VAULT_OUTPUT" | tee /tmp/reiy_fee_vault_deploy.json

  FEE_VAULT_ID=$(echo "$FEE_VAULT_OUTPUT" | jq -r '
    .objectChanges[]
    | select(.type == "created")
    | select(.objectType | test("FeeVault"))
    | .objectId
  ' | head -1)

  if [[ -z "$FEE_VAULT_ID" ]]; then
    echo "ERROR: could not extract FeeVault ID" >&2
    exit 1
  fi
  echo "FeeVault: $FEE_VAULT_ID"
  set_env_var FEE_VAULT_ID "$FEE_VAULT_ID"
  FEE_VAULT_CREATED=1
fi

if [[ "$FEE_VAULT_CREATED" -eq 1 || "${REBIND_CANONICAL_IDS:-0}" == "1" ]]; then
  run_ptb \
    --move-call "${REIY_PACKAGE_ID}::config::register_fee_vault<${USDC_TYPE}>" \
      "@${GLOBAL_CONFIG_ID}" "@${FEE_VAULT_ID}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
else
  echo "Step 3b: fee vault binding already recorded"
fi

echo ""
COORDINATOR_KEY_VERSION=${COORDINATOR_KEY_VERSION:-1}
if [[ -z "${COORDINATOR_PUBKEY:-}" || "${COORDINATOR_PUBKEY}" == "active" ]]; then
  COORDINATOR_PUBKEY=$(derive_active_coordinator_pubkey)
  set_env_var COORDINATOR_PUBKEY "$COORDINATOR_PUBKEY"
fi
COORDINATOR_PUBKEY_BYTES=$(hex_to_u8_array "$COORDINATOR_PUBKEY")
echo "Step 4: set_execution_coordinator key version ${COORDINATOR_KEY_VERSION} ..."
run_ptb \
  --make-move-vec "<u8>" "${COORDINATOR_PUBKEY_BYTES}" \
  --assign coordinator_pubkey \
  --move-call "${REIY_PACKAGE_ID}::config::set_execution_coordinator" \
    "@${GLOBAL_CONFIG_ID}" coordinator_pubkey "${COORDINATOR_KEY_VERSION}" "@${ADMIN_CAP_ID}" \
  --gas-budget "${GAS_BUDGET}"
set_env_var COORDINATOR_KEY_VERSION "$COORDINATOR_KEY_VERSION"

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
echo "Step 5: add_numeraire_pool ..."
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
  if [[ -n "${WUSDC_TYPE:-}" && "${USDC_TYPE}" == "${WUSDC_TYPE}" ]]; then
    add_numeraire_pool_if_set "WSUI -> WUSDC" "${WSUI_TYPE:-}" "${DEEPBOOK_WSUI_WUSDC_POOL:-}"
    add_numeraire_pool_if_set "WDEEP -> WUSDC" "${WDEEP_TYPE:-}" "${DEEPBOOK_WDEEP_WUSDC_POOL:-}"
    add_numeraire_pool_if_set "WUSDT -> WUSDC" "${WUSDT_TYPE:-}" "${DEEPBOOK_WUSDC_WUSDT_POOL:-}"
  else
    echo "  NUMERAIRE_POOLS not set -- skipping legacy WUSDC fallback for active numeraire ${USDC_TYPE}"
  fi
fi

# ---- 6. add_supported_pairs ----
echo ""
echo "Step 6: add_supported_pairs ..."
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

    # v2 launch is numeraire-only: add_supported_pair on-chain requires Buy == numeraire.
    # Fail fast here with a clear message instead of aborting mid-setup with a raw Move abort.
    if [[ "$BUY" != "$USDC_TYPE" ]]; then
      echo "ERROR: numeraire-only launch -- a supported pair's Buy token must be the numeraire." >&2
      echo "       numeraire (USDC_TYPE): ${USDC_TYPE}" >&2
      echo "       offending pair (Sell -> Buy): ${SELL} -> ${BUY}" >&2
      echo "       Remove non-numeraire-Buy pairs from SUPPORTED_PAIRS (e.g. the reverse USDC->X)." >&2
      exit 1
    fi

    echo "  Adding pair: ${SELL} -> ${BUY}"
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::config::add_supported_pair<${SELL},${BUY}>" \
        "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}"
  done
fi

# ---- 7. (mainnet only) transfer AdminCap to multisig ----
if [[ -n "${MULTISIG_ADDRESS:-}" ]]; then
  echo ""
  echo "Step 7: Transferring AdminCap to multisig ${MULTISIG_ADDRESS} ..."
  run_ptb \
    --transfer-objects "[@${ADMIN_CAP_ID}]" "@${MULTISIG_ADDRESS}" \
    --gas-budget "${GAS_BUDGET}"
  echo "✓ AdminCap transferred — you can no longer call setup again without multisig co-sign"
else
  echo "Step 7: MULTISIG_ADDRESS not set -- AdminCap stays with deployer"
fi

echo ""
echo "=== Setup complete ==="
echo "SOLVER_REGISTRY_ID = $REGISTRY_ID"
echo "FEE_VAULT_ID = $FEE_VAULT_ID"
echo "COORDINATOR_KEY_VERSION = $COORDINATOR_KEY_VERSION"
