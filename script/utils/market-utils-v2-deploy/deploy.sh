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

# Check for required environment variables
if [ -z "$MARKET_CONFIG_V2_ADDRESS" ]; then
    echo "Error: MARKET_CONFIG_V2_ADDRESS not set in environment"
    exit 1
fi

# Prepare forge command with library linking
LIBRARIES="src/utils/v2/MarketConfigV2.sol:MarketConfigV2:${MARKET_CONFIG_V2_ADDRESS}"
FORGE_CMD="forge script script/utils/market-utils-v2-deploy/MarketUtilsV2Deploy.s.sol:MarketUtilsV2Deploy --rpc-url ${RPC_URL} -vv --libraries ${LIBRARIES}"

# Add broadcast flag if specified
if [ "$BROADCAST" = true ]; then
    echo "Broadcasting transactions..."
    FORGE_CMD="${FORGE_CMD} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"
else
    echo "Running in simulation mode (no broadcasting)..."
fi

# Execute the forge command
eval "${FORGE_CMD}" 