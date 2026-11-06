#!/usr/bin/env bash
# Shared entry point for fresh Cart and independent Lens deployments.

cart_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cart_repo_root="$(cd -- "${cart_script_dir}/../.." && pwd)"

cart_load_env() {
  local env_file="${CART_ENV_FILE:-}" candidate
  if [[ -z "${env_file}" ]]; then
    for candidate in "${PWD}/.env" "${cart_script_dir}/.env" "${cart_repo_root}/.env"; do
      if [[ -f "${candidate}" ]]; then
        env_file="${candidate}"
        break
      fi
    done
  fi
  if [[ -n "${env_file}" ]]; then
    set -a
    source "${env_file}"
    set +a
  fi
}

cart_run_script() {
  local target="$1"
  shift
  local broadcast=false verify=false resume=false chain_id multiplier dependency arg
  for arg in "$@"; do
    case "${arg}" in
      --broadcast) broadcast=true ;;
      --verify) verify=true ;;
      --resume) resume=true ;;
      *) echo "Usage: $0 [--broadcast [--verify] [--resume]]" >&2; return 2 ;;
    esac
  done
  if [[ "${broadcast}" == false && ( "${verify}" == true || "${resume}" == true ) ]]; then
    echo "--verify and --resume require --broadcast." >&2
    return 2
  fi

  cart_load_env
  : "${RPC_URL:?RPC_URL is required. Set CART_ENV_FILE to select the deployment environment.}"
  : "${PRIVATE_KEY:?PRIVATE_KEY is required}"
  if [[ "${target}" == CartDeploy ]]; then
    : "${CART_PLATFORM_SIGNER:?CART_PLATFORM_SIGNER is required}"
  fi
  if [[ "${verify}" == true ]]; then
    : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required with --verify}"
  fi
  for dependency in cast forge git; do
    command -v "${dependency}" >/dev/null || { echo "Missing required tool: ${dependency}" >&2; return 1; }
  done
  # Do not echo provider errors: authenticated RPC URLs can contain credentials.
  if ! chain_id="$(cast chain-id --rpc-url "${RPC_URL}" 2>/dev/null)"; then
    echo "RPC preflight failed. Check RPC_URL credentials and connectivity. No deployment was started." >&2
    return 1
  fi
  if [[ "${chain_id}" != "${CART_CHAIN_ID:-11155111}" ]]; then
    echo "RPC chain ${chain_id} does not match CART_CHAIN_ID=${CART_CHAIN_ID:-11155111}." >&2
    return 1
  fi
  multiplier="${CART_GAS_ESTIMATE_MULTIPLIER:-150}"
  if ! [[ "${multiplier}" =~ ^[1-9][0-9]*$ ]] || (( multiplier < 100 )); then
    echo "CART_GAS_ESTIMATE_MULTIPLIER must be an integer of at least 100." >&2
    return 1
  fi
  for dependency in lib/forge-std/src/Script.sol lib/ds-test/src/test.sol \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol \
    lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol; do
    if [[ ! -f "${cart_repo_root}/${dependency}" ]]; then
      echo "Missing ${dependency}. Run bash script/cart/setup.sh before deploying." >&2
      return 1
    fi
  done
  if [[ "${broadcast}" == true ]]; then
    bash "${cart_script_dir}/check-checkout.sh" --remote
  else
    bash "${cart_script_dir}/check-checkout.sh"
  fi

  echo "RPC preflight passed on chain ${chain_id}."
  cd "${cart_repo_root}"
  local forge_args=(script "${cart_script_dir}/${target}.s.sol:${target}" --rpc-url "${RPC_URL}" --ast --build-info -vv)
  if [[ "${broadcast}" == true ]]; then
    forge_args+=(--broadcast --slow --skip-simulation --gas-estimate-multiplier "${multiplier}")
  fi
  if [[ "${verify}" == true ]]; then forge_args+=(--verify); fi
  # Resume skips run(), including its vm.startBroadcast wallet registration.
  if [[ "${resume}" == true ]]; then forge_args+=(--resume --private-key "${PRIVATE_KEY}"); fi
  # forge script compiles its inputs directly. Do not precede it with forge build,
  # which tries to install every missing submodule, including unrelated protocols.
  FOUNDRY_PROFILE=cart RUST_LOG="${RUST_LOG:-warn,foundry_evm_traces::debug::sources=error}" forge "${forge_args[@]}"
}
