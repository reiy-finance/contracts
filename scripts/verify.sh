#!/usr/bin/env bash
# Verify a deployed REIY package: check shared objects exist and have expected types.
# Usage: verify.sh <env_file>
set -euo pipefail

ENV_FILE=${1:-.env.testnet}
source "$ENV_FILE"

ok=0; fail=0

check_object() {
  local label=$1 id=$2 pattern=$3
  if [[ -z "$id" ]]; then
    echo "  SKIP  $label (not set in env)" >&2
    return
  fi
  local typ
  typ=$(sui client object "$id" --json 2>/dev/null | jq -r '.data.type // .objType // empty')
  if echo "$typ" | grep -q "$pattern"; then
    echo "  ✓  $label  $id"
    ((ok++)) || true
  else
    echo "  ✗  $label  $id  (got: ${typ:-NOT FOUND})" >&2
    ((fail++)) || true
  fi
}

echo "=== REIY Object Verification (${ENV_FILE}) ==="
check_object "AuctionState"       "${AUCTION_STATE_ID:-}"    "AuctionState"
check_object "GlobalConfig"       "${GLOBAL_CONFIG_ID:-}"    "GlobalConfig"
check_object "SolverRegistry"     "${SOLVER_REGISTRY_ID:-}"  "SolverRegistry"
check_object "FeeVault"           "${FEE_VAULT_ID:-}"        "FeeVault"
echo ""
echo "Passed: $ok  Failed: $fail"
[[ $fail -eq 0 ]]
