#!/usr/bin/env bash
set -euo pipefail
# Load only a caller-selected, trusted environment file. Simulation is the default.
if [[ -n "${MEMBERSHIPS_DEPLOY_ENV:-}" ]]; then
  set -a
  source "$MEMBERSHIPS_DEPLOY_ENV"
  set +a
fi
arguments=(script script/memberships/creator-memberships-deploy/CreatorMembershipsDeploy.s.sol:CreatorMembershipsDeploy --rpc-url "${RPC_URL:?RPC_URL is required}")
if [[ "${1:-}" == "--broadcast" ]]; then
  arguments+=(--broadcast --verify --etherscan-api-key "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required}")
elif [[ $# -gt 0 ]]; then
  echo 'Usage: deploy.sh [--broadcast]' >&2
  exit 1
fi
FOUNDRY_PROFILE=memberships forge "${arguments[@]}"
