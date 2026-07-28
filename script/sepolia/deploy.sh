#!/bin/bash

# Sepolia Deployment Script - Rare Protocol
# Usage: ./script/sepolia/deploy.sh [--broadcast] [--verify]

BROADCAST=false
VERIFY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --broadcast)
      BROADCAST=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    *)
      echo "Unknown parameter: $1"
      echo "Usage: $0 [--broadcast] [--verify]"
      exit 1
      ;;
  esac
done

# Load .env from project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
  echo "Loading environment from .env"
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

if [ -z "$RPC_URL" ]; then
  echo "RPC_URL not set. Using default Sepolia RPC."
  export RPC_URL="https://rpc.sepolia.org"
fi

if [ -z "$RARE_ADDRESS" ]; then
  echo "ERROR: RARE_ADDRESS must be set in .env"
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "ERROR: PRIVATE_KEY must be set in .env"
  exit 1
fi

# Create deployments directory for JSON output
mkdir -p "$PROJECT_ROOT/deployments"

cd "$PROJECT_ROOT"

FORGE_CMD="forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url ${RPC_URL} -vvv"

if [ "$BROADCAST" = true ]; then
  echo "Broadcasting transactions to Sepolia..."
  FORGE_CMD="${FORGE_CMD} --broadcast --chain-id ${CHAIN_ID:-11155111}"
  if [ "$VERIFY" = true ] && [ -n "$ETHERSCAN_API_KEY" ]; then
    FORGE_CMD="${FORGE_CMD} --verify --etherscan-api-key ${ETHERSCAN_API_KEY}"
  fi
else
  echo "Running in simulation mode (no broadcasting)..."
fi

eval "${FORGE_CMD}"
