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

# Set default primary sale fee percentage if not set
if [ -z "$PRIMARY_SALE_FEE_PERCENTAGE" ]; then
    export PRIMARY_SALE_FEE_PERCENTAGE=0
fi

# Validate required environment variables
echo "=== Validating Environment Variables ==="
REQUIRED_VARS=("PRIVATE_KEY" "NETWORK_BENEFICIARY" "ROYALTY_REGISTRY")

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required environment variable $var is not set"
        echo "Please check your .env file and ensure all required variables are configured"
        exit 1
    fi
done

echo "✓ All required environment variables are set"

# Display configuration
echo ""
echo "=== Deployment Configuration ==="
echo "RPC URL: $RPC_URL"
echo "Chain ID: ${CHAIN_ID:-'Not set (will use network default)'}"
echo "Network Beneficiary: $NETWORK_BENEFICIARY"
echo "Royalty Registry: $ROYALTY_REGISTRY"
echo "Primary Sale Fee Percentage: ${PRIMARY_SALE_FEE_PERCENTAGE}"
echo "Staking Fee Percentage: ${STAKING_FEE_PERCENTAGE:-'1 (default)'}"
echo "Broadcast Mode: $BROADCAST"
echo ""

# Display royalty engine source assumptions
if [ -n "$ROYALTY_ENGINE" ]; then
    echo "Royalty Engine Source: env override (ROYALTY_ENGINE=$ROYALTY_ENGINE)"
else
    if [ -n "$CHAIN_ID" ] && [ "$CHAIN_ID" = "8453" ]; then
        echo "Royalty Engine Source: fixed Base engine (0xEF770dFb6D5620977213f55f99bfd781D04BBE15)"
    elif [ -n "$CHAIN_ID" ] && [ "$CHAIN_ID" = "84532" ]; then
        echo "Royalty Engine Source: deploy Base Sepolia zero-royalty engine"
    else
        echo "Royalty Engine Source: auto-resolve from chain at runtime"
        echo "  - Base (8453): fixed engine 0xEF770dFb6D5620977213f55f99bfd781D04BBE15"
        echo "  - Base Sepolia (84532): deploy zero-royalty engine"
        echo "  - Other chains: set ROYALTY_ENGINE to avoid runtime revert"
    fi
fi

# Prepare the base forge command
FORGE_CMD="forge script script/bazaar/bazaar-full-deploy/BazaarFullDeploy.s.sol:BazaarFullDeploy --rpc-url ${RPC_URL} -vv"

# Add broadcast flag if specified
if [ "$BROADCAST" = true ]; then
    echo ""
    echo "=== Broadcasting Transactions ==="
    echo "⚠️  This will deploy contracts to the blockchain!"
    echo "⚠️  Make sure you have sufficient funds for deployment"
    echo ""
    
    # Validate additional required vars for broadcast
    if [ -z "$ETHERSCAN_API_KEY" ] && [ "$BROADCAST" = true ]; then
        echo "WARNING: ETHERSCAN_API_KEY not set. Contract verification will be skipped."
    fi
    
    if [ -z "$CHAIN_ID" ] && [ "$BROADCAST" = true ]; then
        echo "WARNING: CHAIN_ID not set. Using network default."
    fi
    
    FORGE_CMD="${FORGE_CMD} --broadcast"
    
    # Add verification if API key is provided
    if [ -n "$ETHERSCAN_API_KEY" ] && [ -n "$CHAIN_ID" ]; then
        FORGE_CMD="${FORGE_CMD} --verify --etherscan-api-key ${ETHERSCAN_API_KEY} --chain-id ${CHAIN_ID}"
        echo "✓ Contract verification enabled"
    fi
else
    echo ""
    echo "=== Running in Simulation Mode ===  "
    echo "No transactions will be broadcast to the blockchain"
    echo "Use --broadcast flag to deploy for real"
    echo ""
fi

# Execute the forge command
echo "Executing: $FORGE_CMD"
echo ""

eval "${FORGE_CMD}"

# Check exit code
if [ $? -eq 0 ]; then
    echo ""
    echo "=== Deployment Script Completed Successfully ==="
    if [ "$BROADCAST" = true ]; then
        echo "✅ Contracts have been deployed to the blockchain!"
        echo "📋 Check the output above for deployed contract addresses"
        echo "💾 Save the contract addresses for future reference"
    else
        echo "✅ Simulation completed successfully!"
        echo "🚀 Run with --broadcast flag when ready to deploy"
    fi
else
    echo ""
    echo "❌ Deployment script failed!"
    echo "Please check the error messages above and fix any issues"
    exit 1
fi
