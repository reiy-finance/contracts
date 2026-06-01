#!/usr/bin/env bash
# Submit example REIY intents from the active Sui address.
#
# Defaults submit SUI -> USDC intents on testnet, using the gas coin as the
# sell coin. Override values with environment variables or KEY=value make args.

set -euo pipefail

ENV_FILE=${ENV_FILE:-.env.testnet}
COUNT=${COUNT:-1}
SELL_AMOUNT=${SELL_AMOUNT:-10000000}
SLIPPAGE_BPS=${SLIPPAGE_BPS:-500}
TTL_MS=${TTL_MS:-3600000}
PARTIAL_FILLABLE=${PARTIAL_FILLABLE:-false}
GAS_BUDGET=${GAS_BUDGET:-500000000}
SOURCE_COIN=${SOURCE_COIN:-gas}
DIRECTION=${DIRECTION:-base_to_quote}
REFRESH_DEEPBOOK=${REFRESH_DEEPBOOK:-1}
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/reiy_examples}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

source "$ENV_FILE"

required_vars=(REIY_PACKAGE_ID AUCTION_STATE_ID GLOBAL_CONFIG_ID)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set in $ENV_FILE" >&2
    exit 1
  fi
done

BASE_TYPE=${BASE_TYPE:-${SUI_TYPE:-}}
QUOTE_TYPE=${QUOTE_TYPE:-${USDC_TYPE:-}}
POOL_ID=${POOL_ID:-${DEEPBOOK_SUI_DBUSDC_POOL:-${DEEPBOOK_SUI_USDC_POOL:-}}}
CLOCK_ID=${CLOCK_ID:-0x6}

if [[ -z "$BASE_TYPE" || -z "$QUOTE_TYPE" || -z "$POOL_ID" ]]; then
  echo "ERROR: BASE_TYPE, QUOTE_TYPE, or POOL_ID is empty." >&2
  echo "Set them explicitly, or fill SUI_TYPE/USDC_TYPE and DEEPBOOK_SUI_DBUSDC_POOL in $ENV_FILE." >&2
  exit 1
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "ERROR: COUNT must be a positive integer." >&2
  exit 1
fi

if [[ "$PARTIAL_FILLABLE" != "true" && "$PARTIAL_FILLABLE" != "false" ]]; then
  echo "ERROR: PARTIAL_FILLABLE must be true or false." >&2
  exit 1
fi

if [[ "$DIRECTION" != "base_to_quote" && "$DIRECTION" != "quote_to_base" ]]; then
  echo "ERROR: DIRECTION must be base_to_quote or quote_to_base." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

now_ms() {
  echo "$(($(date +%s) * 1000))"
}

coin_source_arg() {
  if [[ "$SOURCE_COIN" == "gas" ]]; then
    echo "gas"
  else
    echo "@$SOURCE_COIN"
  fi
}

append_deepbook_refresh_args() {
  if [[ "$REFRESH_DEEPBOOK" != "1" || -z "${DEEPBOOK_PKG:-}" || -z "${DEEPBOOK_REGISTRY:-}" ]]; then
    return
  fi

  args+=(
    --move-call "${DEEPBOOK_PKG}::pool::update_pool_allowed_versions<${BASE_TYPE},${QUOTE_TYPE}>"
      "@${POOL_ID}" "@${DEEPBOOK_REGISTRY}"
  )
}

append_min_amount_args() {
  local min_var=$1

  args+=(
    --move-call "${REIY_PACKAGE_ID}::price_adapter::read_mid_price<${BASE_TYPE},${QUOTE_TYPE}>"
      "@${POOL_ID}" "@${GLOBAL_CONFIG_ID}" "@${CLOCK_ID}"
    --assign mid_price
  )

  if [[ "$DIRECTION" == "base_to_quote" ]]; then
    args+=(
      --move-call "${REIY_PACKAGE_ID}::price_adapter::sbbo_floor_base_to_quote"
        "$SELL_AMOUNT" mid_price "$SLIPPAGE_BPS"
      --assign "$min_var"
    )
  else
    args+=(
      --move-call "${REIY_PACKAGE_ID}::price_adapter::sbbo_floor_quote_to_base"
        "$SELL_AMOUNT" mid_price "$SLIPPAGE_BPS"
      --assign "$min_var"
    )
  fi
}

intent_id_from_json() {
  jq -r '
    .objectChanges[]
    | select(.type == "created" or .type == "published")
    | select((.objectType // "") | test("::intent_book::Intent<"))
    | .objectId
  ' "$1" | head -1
}

echo "=== Submit REIY Example Intents ==="
echo "Env        : $ENV_FILE"
echo "Package    : $REIY_PACKAGE_ID"
echo "Auction    : $AUCTION_STATE_ID"
echo "Config     : $GLOBAL_CONFIG_ID"
echo "Direction  : $DIRECTION"
echo "Pool       : $POOL_ID"
echo "Sell amount: $SELL_AMOUNT"
echo "Count      : $COUNT"
echo ""

i=1
while [[ "$i" -le "$COUNT" ]]; do
  deadline=$(($(now_ms) + TTL_MS))
  out_json="${OUTPUT_DIR}/submit_intent_${i}.json"
  coin_var="sell_coin_${i}"
  min_var="min_out_${i}"
  min_arg="$min_var"
  args=()

  append_deepbook_refresh_args
  if [[ -n "${MIN_AMOUNT_OUT:-}" ]]; then
    min_arg="$MIN_AMOUNT_OUT"
  else
    append_min_amount_args "$min_var"
  fi
  args+=(
    --split-coins "$(coin_source_arg)" "[$SELL_AMOUNT]"
    --assign "$coin_var"
  )

  if [[ "$DIRECTION" == "base_to_quote" ]]; then
    args+=(
      --move-call "${REIY_PACKAGE_ID}::auction::submit_intent_sell_base<${BASE_TYPE},${QUOTE_TYPE}>"
        "@${AUCTION_STATE_ID}" "@${GLOBAL_CONFIG_ID}" "@${POOL_ID}"
        "$coin_var" "$min_arg" "$SLIPPAGE_BPS" "$PARTIAL_FILLABLE" "$deadline" "@${CLOCK_ID}"
    )
  else
    args+=(
      --move-call "${REIY_PACKAGE_ID}::auction::submit_intent_sell_quote<${BASE_TYPE},${QUOTE_TYPE}>"
        "@${AUCTION_STATE_ID}" "@${GLOBAL_CONFIG_ID}" "@${POOL_ID}"
        "$coin_var" "$min_arg" "$SLIPPAGE_BPS" "$PARTIAL_FILLABLE" "$deadline" "@${CLOCK_ID}"
    )
  fi

  args+=(--gas-budget "$GAS_BUDGET" --json)

  echo "[$i/$COUNT] submitting intent..."
  if sui client ptb "${args[@]}" > "$out_json"; then
    digest=$(jq -r '.digest // empty' "$out_json")
    intent_id=$(intent_id_from_json "$out_json")
    echo "  tx       : ${digest:-unknown}"
    echo "  intent   : ${intent_id:-not found in objectChanges}"
    echo "  output   : $out_json"
  else
    echo "ERROR: submit failed. Last output path: $out_json" >&2
    exit 1
  fi

  i=$((i + 1))
done
