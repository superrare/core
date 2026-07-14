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

if [ -z "$MARKETPLACE_ADDRESS" ]; then
    echo "Error: MARKETPLACE_ADDRESS environment variable is required"
    echo "Set MARKETPLACE_ADDRESS to your deployed RareBatchListingMarketplace address"
    exit 1
fi

if [ -z "$MERKLE_ROOT" ]; then
    echo "Error: MERKLE_ROOT environment variable is required"
    echo "Set MERKLE_ROOT to the Merkle root of your token set"
    echo "The Merkle root should be computed from leaves: keccak256(abi.encodePacked(contractAddress, tokenId))"
    exit 1
fi

if [ -z "$SALE_PRICE_AMOUNT" ]; then
    echo "Error: SALE_PRICE_AMOUNT environment variable is required"
    echo "Set SALE_PRICE_AMOUNT to the sale price amount (in wei for ETH, or smallest unit for ERC20)"
    exit 1
fi

# Validate optional split configuration
# SPLIT_ADDRESSES and SPLIT_RATIOS should be comma-separated values
# Example: SPLIT_ADDRESSES="0x123...,0x456..." SPLIT_RATIOS="50,50"
if [ -n "$SPLIT_ADDRESSES" ] && [ -z "$SPLIT_RATIOS" ]; then
    echo "Error: SPLIT_RATIOS is required when SPLIT_ADDRESSES is provided"
    exit 1
fi

if [ -z "$SPLIT_ADDRESSES" ] && [ -n "$SPLIT_RATIOS" ]; then
    echo "Error: SPLIT_ADDRESSES is required when SPLIT_RATIOS is provided"
    exit 1
fi

# Validate split arrays have same length
if [ -n "$SPLIT_ADDRESSES" ] && [ -n "$SPLIT_RATIOS" ]; then
    ADDR_COUNT=$(echo "$SPLIT_ADDRESSES" | tr ',' '\n' | wc -l | tr -d ' ')
    RATIO_COUNT=$(echo "$SPLIT_RATIOS" | tr ',' '\n' | wc -l | tr -d ' ')
    if [ "$ADDR_COUNT" -ne "$RATIO_COUNT" ]; then
        echo "Error: SPLIT_ADDRESSES and SPLIT_RATIOS must have the same number of values"
        echo "  Addresses: $ADDR_COUNT, Ratios: $RATIO_COUNT"
        exit 1
    fi
fi

# Validate allowlist configuration if provided
if [ -n "$ALLOWLIST_ROOT" ] && [ -z "$ALLOWLIST_END_TIMESTAMP" ]; then
    echo "Error: ALLOWLIST_END_TIMESTAMP is required when ALLOWLIST_ROOT is provided"
    exit 1
fi

# Validate marketplace approval configuration if provided
if [ -n "$NFT_CONTRACT" ] && [ -z "$ERC721_APPROVAL_MANAGER" ]; then
    echo "Error: ERC721_APPROVAL_MANAGER is required when NFT_CONTRACT is provided"
    echo "Set ERC721_APPROVAL_MANAGER to the ERC721ApprovalManager contract address"
    exit 1
fi

# Warn if NFT_CONTRACT is not set (approval won't happen)
if [ -z "$NFT_CONTRACT" ]; then
    echo "Warning: NFT_CONTRACT not set. Marketplace approval will be skipped."
    echo "You may need to manually approve the marketplace before tokens can be purchased."
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
FORGE_CMD="forge script script/token/sovereign/lazy-sovereign-batch-mint-factory-deploy/configure-batch-listing.s.sol:ConfigureBatchListingScript --rpc-url ${RPC_URL} --via-ir -vv"

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
