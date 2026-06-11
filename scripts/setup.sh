#!/usr/bin/env bash
# Post-deploy protocol setup.
# Usage: setup.sh <env_file>
set -euo pipefail

ENV_FILE=${1:-.env.testnet}
source "$ENV_FILE"

required_vars=(
  REIY_PACKAGE_ID GLOBAL_CONFIG_ID ADMIN_CAP_ID
  SUI_TYPE GAS_BUDGET
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

REGISTRY_ID=${SOLVER_REGISTRY_ID:-}
REGISTRY_CREATED=0
if [[ -n "$REGISTRY_ID" ]]; then
  echo "Step 1: use SolverRegistry ${REGISTRY_ID}"
else
  echo "Step 1: init_registry<${STAKE_TYPE}> ..."
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
  echo "Step 1b: registry binding already recorded"
fi

echo ""
FEE_VAULT_ENTRIES=${FEE_VAULTS:-}
FEE_VAULT_ID=${FEE_VAULT_ID:-}
if [[ -n "${FEE_VAULT_ID}" && -n "${USDC_TYPE:-}" ]]; then
  FEE_VAULT_ENTRIES="${FEE_VAULT_ENTRIES:+$FEE_VAULT_ENTRIES }${USDC_TYPE}|${FEE_VAULT_ID}"
fi

parse_pair() {
  local pair=$1
  local sell
  local buy

  if [[ "$pair" == *"|"* ]]; then
    sell=${pair%%|*}
    buy=${pair#*|}
  elif [[ "$pair" == *":0x"* ]]; then
    sell=${pair%%:0x*}
    buy=0x${pair#*:0x}
  else
    echo "ERROR: unsupported pair format: $pair" >&2
    echo "Use SELL_TYPE:BUY_TYPE or SELL_TYPE|BUY_TYPE" >&2
    exit 1
  fi

  if [[ -z "$sell" || -z "$buy" || "$sell" == "$buy" ]]; then
    echo "ERROR: could not parse supported pair: $pair" >&2
    exit 1
  fi

  printf "%s|%s" "$sell" "$buy"
}

parse_fee_vault_entry() {
  local entry=$1
  local token_type
  local vault_id

  if [[ "$entry" == *"|"* ]]; then
    token_type=${entry%%|*}
    vault_id=${entry#*|}
  elif [[ "$entry" == *":0x"* ]]; then
    token_type=${entry%%:0x*}
    vault_id=0x${entry#*:0x}
  else
    echo "ERROR: unsupported fee vault format: $entry" >&2
    echo "Use TOKEN_TYPE|FEE_VAULT_ID" >&2
    exit 1
  fi

  if [[ -z "$token_type" || -z "$vault_id" ]]; then
    echo "ERROR: could not parse fee vault entry: $entry" >&2
    exit 1
  fi

  printf "%s|%s" "$token_type" "$vault_id"
}

add_unique_token() {
  local list=$1
  local token=$2
  local existing
  for existing in $list; do
    if [[ "$existing" == "$token" ]]; then
      printf "%s" "$list"
      return
    fi
  done
  printf "%s%s%s" "$list" "${list:+ }" "$token"
}

fee_vault_for_token() {
  local token=$1
  local entry
  for entry in $FEE_VAULT_ENTRIES; do
    local parsed
    parsed=$(parse_fee_vault_entry "$entry")
    local token_type=${parsed%%|*}
    local vault_id=${parsed#*|}
    if [[ "$token_type" == "$token" ]]; then
      printf "%s" "$vault_id"
      return
    fi
  done
}

ensure_fee_vault() {
  local token_type=$1
  local vault_id
  vault_id=$(fee_vault_for_token "$token_type")

  if [[ -n "$vault_id" ]]; then
    echo "  Using FeeVault<${token_type}> ${vault_id}"
  else
    echo "  Creating FeeVault<${token_type}> ..."
    local output
    output=$(
      run_ptb \
        --move-call "${REIY_PACKAGE_ID}::fee_vault::init_fee_vault<${token_type}>" \
          "@${ADMIN_CAP_ID}" \
        --gas-budget "${GAS_BUDGET}" \
        --json 2>&1
    ) || {
      echo "$output" >&2
      exit 1
    }
    echo "$output" | tee /tmp/reiy_fee_vault_deploy.json

    vault_id=$(echo "$output" | jq -r '
      .objectChanges[]
      | select(.type == "created")
      | select(.objectType | test("FeeVault"))
      | .objectId
    ' | head -1)

    if [[ -z "$vault_id" ]]; then
      echo "ERROR: could not extract FeeVault ID" >&2
      exit 1
    fi
    FEE_VAULT_ENTRIES="${FEE_VAULT_ENTRIES:+$FEE_VAULT_ENTRIES }${token_type}|${vault_id}"
    if [[ -z "${FEE_VAULT_ID:-}" ]]; then
      FEE_VAULT_ID=$vault_id
      set_env_var FEE_VAULT_ID "$FEE_VAULT_ID"
    fi
  fi

  run_ptb \
    --move-call "${REIY_PACKAGE_ID}::config::register_fee_vault<${token_type}>" \
      "@${GLOBAL_CONFIG_ID}" "@${vault_id}" "@${ADMIN_CAP_ID}" \
    --gas-budget "${GAS_BUDGET}"
}

BUY_TYPES=""
if [[ -n "${SUPPORTED_PAIRS:-}" ]]; then
  for PAIR in $SUPPORTED_PAIRS; do
    PARSED_PAIR=$(parse_pair "$PAIR")
    BUY_TYPES=$(add_unique_token "$BUY_TYPES" "${PARSED_PAIR#*|}")
  done
fi
if [[ -n "$FEE_VAULT_ENTRIES" ]]; then
  for ENTRY in $FEE_VAULT_ENTRIES; do
    PARSED_VAULT=$(parse_fee_vault_entry "$ENTRY")
    BUY_TYPES=$(add_unique_token "$BUY_TYPES" "${PARSED_VAULT%%|*}")
  done
fi

echo "Step 2: ensure FeeVault<Buy> registrations ..."
if [[ -z "$BUY_TYPES" ]]; then
  echo "  No supported pairs or fee vault entries configured"
else
  for BUY_TYPE in $BUY_TYPES; do
    ensure_fee_vault "$BUY_TYPE"
  done
fi

echo ""
COORDINATOR_KEY_VERSION=${COORDINATOR_KEY_VERSION:-1}
if [[ -z "${COORDINATOR_PUBKEY:-}" || "${COORDINATOR_PUBKEY}" == "active" ]]; then
  COORDINATOR_PUBKEY=$(derive_active_coordinator_pubkey)
  set_env_var COORDINATOR_PUBKEY "$COORDINATOR_PUBKEY"
fi
COORDINATOR_PUBKEY_BYTES=$(hex_to_u8_array "$COORDINATOR_PUBKEY")
echo "Step 3: set_execution_coordinator key version ${COORDINATOR_KEY_VERSION} ..."
run_ptb \
  --make-move-vec "<u8>" "${COORDINATOR_PUBKEY_BYTES}" \
  --assign coordinator_pubkey \
  --move-call "${REIY_PACKAGE_ID}::config::set_execution_coordinator" \
    "@${GLOBAL_CONFIG_ID}" coordinator_pubkey "${COORDINATOR_KEY_VERSION}" "@${ADMIN_CAP_ID}" \
  --gas-budget "${GAS_BUDGET}"
set_env_var COORDINATOR_KEY_VERSION "$COORDINATOR_KEY_VERSION"

echo ""
echo "Step 4: add_supported_pairs ..."
if [[ -z "${SUPPORTED_PAIRS:-}" ]]; then
  echo "SUPPORTED_PAIRS not set — skipping"
else
  for PAIR in $SUPPORTED_PAIRS; do
    PARSED_PAIR=$(parse_pair "$PAIR")
    SELL=${PARSED_PAIR%%|*}
    BUY=${PARSED_PAIR#*|}

    echo "  Adding pair: ${SELL} -> ${BUY}"
    run_ptb \
      --move-call "${REIY_PACKAGE_ID}::config::add_supported_pair<${SELL},${BUY}>" \
        "@${GLOBAL_CONFIG_ID}" "@${ADMIN_CAP_ID}" \
      --gas-budget "${GAS_BUDGET}"
  done
fi

if [[ -n "${MULTISIG_ADDRESS:-}" ]]; then
  echo ""
  echo "Step 5: Transferring AdminCap to multisig ${MULTISIG_ADDRESS} ..."
  run_ptb \
    --transfer-objects "[@${ADMIN_CAP_ID}]" "@${MULTISIG_ADDRESS}" \
    --gas-budget "${GAS_BUDGET}"
  echo "✓ AdminCap transferred — you can no longer call setup again without multisig co-sign"
else
  echo "Step 5: MULTISIG_ADDRESS not set -- AdminCap stays with deployer"
fi

echo ""
echo "=== Setup complete ==="
echo "SOLVER_REGISTRY_ID = $REGISTRY_ID"
echo "FEE_VAULTS = $FEE_VAULT_ENTRIES"
echo "COORDINATOR_KEY_VERSION = $COORDINATOR_KEY_VERSION"
