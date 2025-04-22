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
            echo "Usage: ./deploy.sh [--broadcast]"
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
else
    echo "No .env file found. Please create one based on .env.sample"
    exit 1
fi

# Check required environment variables
if [ -z "$RPC_URL" ]; then
    echo "Error: RPC_URL not set in .env"
    exit 1
fi

# Prepare forge command
FORGE_CMD="forge script script/approver/approval-manager-deploy/ApprovalManagerDeploy.s.sol:ApprovalManagerDeploy --rpc-url ${RPC_URL} -vvv"

# Add broadcast and verify flags if specified
if [ "$BROADCAST" = true ]; then
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        echo "Error: ETHERSCAN_API_KEY not set in .env"
        exit 1
    fi
    echo "Broadcasting transactions and verifying contracts..."
    FORGE_CMD="${FORGE_CMD} --broadcast --verify --etherscan-api-key ${ETHERSCAN_API_KEY}"
else
    echo "Running in simulation mode (no broadcasting)..."
fi

# Execute the forge command
eval "${FORGE_CMD}" 