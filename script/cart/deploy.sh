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

: "${RPC_URL:?RPC_URL environment variable is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY environment variable is required}"
: "${CART_PLATFORM_SIGNER:?CART_PLATFORM_SIGNER environment variable is required}"

resolved_chain_id="$(cast chain-id --rpc-url "${RPC_URL}")"

echo "RPC chain ID: ${resolved_chain_id}"

cd "${repo_root}"
forge_args=(
  script
  "${script_dir}/CartDeploy.s.sol:CartDeploy"
  --rpc-url "${RPC_URL}"
  -vv
)
if [[ "${should_broadcast}" == true ]]; then
  forge_args+=(--broadcast)
fi
FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-cart}" forge "${forge_args[@]}"
