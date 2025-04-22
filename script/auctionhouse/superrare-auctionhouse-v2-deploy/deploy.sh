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

# Load .env file if it exists in the current directory
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

# Set default verbosity if not set
if [ -z "$VERBOSITY" ]; then
    export VERBOSITY=1
fi

# Prepare the base forge command
FORGE_CMD="forge script script/auctionhouse/superrare-auctionhouse-v2-deploy/SuperRareAuctionHouseV2Deploy.s.sol:SuperRareAuctionHouseV2Deploy --rpc-url ${RPC_URL} -vv --libraries src/utils/v2/MarketUtilsV2.sol:MarketUtilsV2=${MARKET_UTILS_LIB_ADDRESS}"
FORGE_CMD_BROADCAST="${FORGE_CMD} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"

# Add broadcast flag if specified
if [ "$BROADCAST" = true ]; then
    echo "Broadcasting transactions..."
    FORGE_CMD="${FORGE_CMD} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"
else
    echo "Running in simulation mode (no broadcasting)..."
    eval "${FORGE_CMD}"
fi
