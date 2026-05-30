#!/usr/bin/env bash
# Extract shared-object and capability IDs from `sui client publish --json` output.
# Usage: extract_ids.sh <publish_output.json> <env_file> <package_name>
set -euo pipefail

JSON=$1
ENV_FILE=$2
PKG=$3  # package name kept for CLI compatibility/logging

if [[ ! -f "$JSON" ]]; then
  echo "ERROR: publish output file not found: $JSON" >&2
  exit 1
fi

echo "Extracting IDs from $JSON ..."

# Package ID
PACKAGE_ID=$(jq -r '[.objectChanges[] | select(.type == "published") | .packageId][0] // ""' "$JSON")

# Helper: find first created object by exact type.
find_created_object() {
  local object_type=$1
  jq -r --arg t "$object_type" '
    .objectChanges[]
    | select(.type == "created")
    | select(.objectType == $t)
    | .objectId
  ' "$JSON" | head -n 1
}

AUCTION_STATE_ID=$(find_created_object "${PACKAGE_ID}::auction::AuctionState")
GLOBAL_CONFIG_ID=$(find_created_object "${PACKAGE_ID}::config::GlobalConfig")
SOLVER_REGISTRY_ID=$(find_created_object "${PACKAGE_ID}::solver_registry::SolverRegistry")
ADMIN_CAP_ID=$(find_created_object "${PACKAGE_ID}::config::AdminCap")
UPGRADE_CAP_ID=$(find_created_object "0x2::package::UpgradeCap")

echo "REIY_PACKAGE_ID=$PACKAGE_ID"
echo "AUCTION_STATE_ID=$AUCTION_STATE_ID"
echo "GLOBAL_CONFIG_ID=$GLOBAL_CONFIG_ID"
echo "SOLVER_REGISTRY_ID=$SOLVER_REGISTRY_ID"
echo "ADMIN_CAP_ID=$ADMIN_CAP_ID"
echo "UPGRADE_CAP_ID=$UPGRADE_CAP_ID"

missing=0
for key in \
  PACKAGE_ID AUCTION_STATE_ID GLOBAL_CONFIG_ID SOLVER_REGISTRY_ID ADMIN_CAP_ID UPGRADE_CAP_ID
do
  if [[ -z "${!key}" ]]; then
    echo "ERROR: could not extract $key from $JSON" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "ERROR: not writing incomplete deployment IDs to $ENV_FILE" >&2
  exit 1
fi

# Write / update env file using sed-safe approach (no in-place issues on macOS)
set_var() {
  local key=$1 val=$2
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

set_var REIY_PACKAGE_ID     "$PACKAGE_ID"
set_var AUCTION_STATE_ID    "$AUCTION_STATE_ID"
set_var GLOBAL_CONFIG_ID    "$GLOBAL_CONFIG_ID"
set_var SOLVER_REGISTRY_ID  "$SOLVER_REGISTRY_ID"
set_var ADMIN_CAP_ID        "$ADMIN_CAP_ID"
set_var UPGRADE_CAP_ID      "$UPGRADE_CAP_ID"

echo "✓ IDs written to $ENV_FILE"
