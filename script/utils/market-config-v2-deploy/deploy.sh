#!/bin/bash

# Default broadcast to false
BROADCAST=false

# Parse command line arguments
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

# Load .env file
if [ -f .env ]; then
    echo "Loading environment from .env file"
    set -o allexport
    source .env
    set +o allexport
fi

# Set default RPC URL if not set
if [ -z "$RPC_URL" ]; then
    echo "RPC_URL not set. Using default localhost:8545"
    export RPC_URL="http://localhost:8545"
fi

# Prepare forge command
FORGE_CMD="forge script script/utils/market-config-v2-deploy/MarketConfigV2Deploy.s.sol:MarketConfigV2Deploy --rpc-url ${RPC_URL} -vv"

# Add broadcast flag if specified
if [ "$BROADCAST" = true ]; then
    echo "Broadcasting transactions..."
    FORGE_CMD="${FORGE_CMD} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"
else
    echo "Running in simulation mode (no broadcasting)..."
fi

# Execute the forge command
eval "${FORGE_CMD}" 