#!/bin/bash

BROADCAST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --broadcast)
            BROADCAST=true
            shift
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [ -f .env ]; then
    echo "Loading environment from .env file"
    set -o allexport
    source .env
    set +o allexport
fi

if [ -z "$RPC_URL" ]; then
    echo "RPC_URL not set. Using default localhost:8545"
    export RPC_URL="http://localhost:8545"
fi

REQUIRED_VARS=("PRIVATE_KEY" "BAZAAR_ADDRESS")

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required environment variable $var is not set"
        exit 1
    fi
done

FORGE_CMD="forge script script/bazaar/BazaarERC20BuyProxyDeploy.s.sol:BazaarERC20BuyProxyDeploy --rpc-url ${RPC_URL} -vv"

if [ "$BROADCAST" = true ]; then
    FORGE_CMD="${FORGE_CMD} --broadcast"

    if [ -n "$ETHERSCAN_API_KEY" ] && [ -n "$CHAIN_ID" ]; then
        FORGE_CMD="${FORGE_CMD} --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"
    fi
fi

echo "Executing: $FORGE_CMD"
eval "${FORGE_CMD}"
