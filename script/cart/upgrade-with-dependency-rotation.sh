#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
env_file="${CART_ENV_FILE:-}"
if [[ -z "${env_file}" ]]; then
  if [[ -f "${PWD}/.env" ]]; then
    env_file="${PWD}/.env"
  elif [[ -f "${script_dir}/.env" ]]; then
    env_file="${script_dir}/.env"
  elif [[ -f "${repo_root}/.env" ]]; then
    env_file="${repo_root}/.env"
  fi
fi
if [[ -n "${env_file}" ]]; then
  set -a
  source "${env_file}"
  set +a
fi

case "${1:-}" in
  "")
    should_broadcast=false
    ;;
  --broadcast)
    should_broadcast=true
    ;;
  *)
    echo "Usage: $0 [--broadcast]" >&2
    exit 2
    ;;
esac

if [[ "${should_broadcast}" == true ]]; then
  bash "${script_dir}/check-checkout.sh" --remote
else
  bash "${script_dir}/check-checkout.sh"
fi

: "${RPC_URL:?RPC_URL environment variable is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY environment variable is required}"

resolved_chain_id="$(cast chain-id --rpc-url "${RPC_URL}")"

echo "RPC chain ID: ${resolved_chain_id}"

cd "${repo_root}"
forge_args=(
  script
  "${script_dir}/CartUpgrade.s.sol:CartUpgrade"
  --rpc-url "${RPC_URL}"
  --gas-estimate-multiplier "${CART_GAS_ESTIMATE_MULTIPLIER:-150}"
  -vv
)
if [[ "${should_broadcast}" == true ]]; then
  # Keep delegated EOA transactions sequential. Use live RPC gas estimates rather than
  # Foundry's local gas schedule, which may lag network state-creation repricing.
  # The script's dependency and owner checks still run before broadcasting.
  forge_args+=(--broadcast --slow --skip-simulation)
fi
FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-cart}" forge "${forge_args[@]}"
