#!/usr/bin/env bash
# Extract shared-object and capability IDs from `sui client publish --json` output.
# Usage: extract_ids.sh <publish_output.json> <env_file>
set -euo pipefail

JSON=$1
ENV_FILE=$2
PKG=$3  # package name prefix for type filtering (e.g. "reiy")

if [[ ! -f "$JSON" ]]; then
  echo "ERROR: publish output file not found: $JSON" >&2
  exit 1
fi

echo "Extracting IDs from $JSON ..."

# Package ID
PACKAGE_ID=$(jq -r '.objectChanges[] | select(.type == "published") | .packageId' "$JSON")

# Helper: find first object whose objectType contains a string
find_object() {
  local pattern=$1
  jq -r --arg p "$pattern" '
    .objectChanges[]
    | select(.type == "created")
    | select(.objectType | test($p; "i"))
    | .objectId
  ' "$JSON" | head -1
}

AUCTION_STATE_ID=$(find_object "${PKG}::auction::AuctionState")
GLOBAL_CONFIG_ID=$(find_object "${PKG}::config::GlobalConfig")
SOLVER_REGISTRY_ID=$(find_object "${PKG}::solver_registry::SolverRegistry")
ADMIN_CAP_ID=$(find_object "${PKG}::config::AdminCap")
UPGRADE_CAP_ID=$(find_object "UpgradeCap")

echo "REIY_PACKAGE_ID=$PACKAGE_ID"
echo "AUCTION_STATE_ID=$AUCTION_STATE_ID"
echo "GLOBAL_CONFIG_ID=$GLOBAL_CONFIG_ID"
echo "SOLVER_REGISTRY_ID=$SOLVER_REGISTRY_ID"
echo "ADMIN_CAP_ID=$ADMIN_CAP_ID"
echo "UPGRADE_CAP_ID=$UPGRADE_CAP_ID"

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
