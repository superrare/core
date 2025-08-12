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
            echo "Usage: $0 [--broadcast]"
            echo "  --broadcast  : Execute transactions on-chain (default: simulation only)"
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

# Validate required environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable is required"
    exit 1
fi

if [ "$BROADCAST" = true ]; then
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        echo "Warning: ETHERSCAN_API_KEY not set. Contract verification will be skipped."
    fi
    if [ -z "$CHAIN_ID" ]; then
        echo "Error: CHAIN_ID environment variable is required for broadcasting"
        exit 1
    fi
fi

# Prepare forge command
FORGE_CMD="forge script script/token/sovereign/sovereign-batch-mint-factory-deploy/SovereignBatchMintFactoryDeploy.s.sol:SovereignBatchMintFactoryDeploy --rpc-url ${RPC_URL} --via-ir  -vv"

# Add broadcast flag if specified
if [ "$BROADCAST" = true ]; then
    echo "Broadcasting transactions to chain ID: ${CHAIN_ID}..."
    FORGE_CMD="${FORGE_CMD} --broadcast --chain-id ${CHAIN_ID}"
    
    # Add verification if API key is provided
    if [ -n "$ETHERSCAN_API_KEY" ]; then
        FORGE_CMD="${FORGE_CMD} --verify --etherscan-api-key ${ETHERSCAN_API_KEY}"
    fi
else
    echo "Running in simulation mode (no broadcasting)..."
fi

# Execute the command
echo "Executing: ${FORGE_CMD}"
eval "${FORGE_CMD}"
