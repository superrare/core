#!/usr/bin/env bash
set -euo pipefail

build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT

if ! forge build --extra-output storageLayout --skip test --skip script >"$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi

check_storage_less_module() {
  local contract="$1"
  local layout
  layout="$(forge inspect "$contract" storage-layout --json | tr -d '[:space:]')"

  if [[ "$layout" != '{"storage":[],"types":{}}' ]]; then
    echo "$contract must remain storage-less except for immutables." >&2
    forge inspect "$contract" storage-layout --json >&2
    exit 1
  fi
}

marketplace_layout="$(forge inspect RareERC1155Marketplace storage-layout --json)"
unexpected_marketplace_labels="$(
  printf "%s\n" "$marketplace_layout" \
    | sed '/"types"/,$d' \
    | grep '"label"' \
    | grep -Ev '"label": "(_initialized|_initializing|_owner|_status|__gap)"' \
    || true
)"

if [[ -n "$unexpected_marketplace_labels" ]]; then
  echo "RareERC1155Marketplace has unexpected non-namespaced storage labels:" >&2
  printf "%s\n" "$unexpected_marketplace_labels" >&2
  exit 1
fi

check_storage_less_module RareERC1155TradeExecutionModule
check_storage_less_module RareERC1155CheckoutExecutionModule

echo "ERC1155 marketplace storage layout guard passed."
