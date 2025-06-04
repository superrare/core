# SuperRare Auction House V2 Implementation Analysis

## Contract Analysis Findings

This document summarizes the analysis of existing contract implementations and outlines the key components to migrate to the new `SuperRareAuctionHouseV2` contract.

### 1. Standard Auction Functions from SuperRare Bazaar

#### Key Functions to Migrate:
- `configureAuction`: Configure auction parameters for a token
- `bid`: Place a bid on an auction
- `cancelAuction`: Cancel an auction that hasn't started
- `settleAuction`: Settle an auction after it's ended
- `getAuctionDetails`: Get the details of an existing auction

#### Required Storage:
- `tokenAuctions`: Mapping from (token contract, token ID) to Auction struct
- `auctionBids`: Mapping from (token contract, token ID) to Bid struct
- Auction settings:
  - `minimumBidIncreasePercentage`: Percentage increase required for new bids
  - `maxAuctionLength`: Maximum allowed auction duration
  - `auctionLengthExtension`: Time extension when bids are placed near expiration

#### Constants:
- `NO_AUCTION`: Indicates no auction exists
- `SCHEDULED_AUCTION`: For auctions with a scheduled future start time
- `COLDIE_AUCTION`: For reserve price auctions (start immediately)

### 2. Merkle Auction Functions from SuperRare Auction House

#### Key Functions to Migrate:
- `registerAuctionMerkleRoot`: Register a new Merkle root for batched auctions
- `cancelAuctionMerkleRoot`: Cancel a Merkle root
- `bidWithAuctionMerkleProof`: Place a bid using a Merkle proof
- Getter functions:
  - `getUserAuctionMerkleRoots`: Get all Merkle roots registered by a user
  - `getCreatorAuctionMerkleRootNonce`: Get the nonce for a user's Merkle root
  - `isTokenInRoot`: Check if a token is included in a Merkle root
  - `getMerkleAuctionConfig`: Get auction configuration for a Merkle root
  - `getTokenAuctionNonce`: Get the nonce for a token in a Merkle auction

#### Required Storage:
- `creatorAuctionMerkleRoots`: Mapping from creator address to their Merkle roots
- `creatorRootToConfig`: Mapping from (creator, root) to MerkleAuctionConfig
- `creatorRootNonce`: Mapping from (creator, root) to nonce
- `tokenAuctionNonce`: Mapping from (creator, root, token contract, token ID) to nonce

### 3. MarketUtilsV2 Integration

#### Key Changes:
- Use `MarketUtilsV2` for all market operations:
  - Currency approval checks
  - NFT approval checks
  - Token transfer handling
  - Fee calculations
  - Payout handling
- Use `MarketConfigV2` to manage marketplace configuration
- Eliminate dependencies on SuperRareBazaarBase and SuperRareBazaarStorage

### 4. Differences in V2 Implementation

#### Removed Components:
- `convertOfferToAuction`: This functionality will not be migrated
- Direct use of MarketUtils (V1)
- Direct dependency on Bazaar contracts

#### Added or Modified Components:
- Centralized storage management in V2 contract
- Unified event definitions
- ETH fallback protection
- Explicit exclusivity between standard and Merkle auctions

### 5. Interface Considerations

- The V2 interface includes all necessary function signatures
- Struct definitions must be consistent with implementation
- Event signatures must match existing events for backward compatibility
- Removed deprecated functions from the interface

### 6. Structs and Events

#### Key Structs:
- `Auction`: Representing standard auction configurations
- `Bid`: Representing bids placed on auctions
- `MerkleAuctionConfig`: Representing Merkle auction configurations

#### Key Events:
- `NewAuction`: When an auction is configured
- `CancelAuction`: When an auction is cancelled
- `AuctionBid`: When a bid is placed
- `AuctionSettled`: When an auction is settled
- `AuctionMerkleRootRegistered`: When a Merkle root is registered
- `AuctionMerkleRootCancelled`: When a Merkle root is cancelled
- `AuctionMerkleBid`: When a bid with Merkle proof is placed

## Implementation Recommendations

1. **Standard Auction Flow:**
   - Create auction → Place bids → Settle or Cancel
   - Use MarketUtilsV2 for token transfers and fee calculations
   - Keep the auction mechanics consistent with existing Bazaar

2. **Merkle Auction Flow:**
   - Register root → Verify token with proof → Place bids → Settle
   - Keep the nonce-based replay protection
   - Utilize MarketUtilsV2 for payouts

3. **Mutual Exclusivity:**
   - A token cannot be in a standard auction and Merkle auction simultaneously
   - This needs checks in both `configureAuction` and `bidWithAuctionMerkleProof`

4. **Prioritize Robustness:**
   - Thorough validation of inputs
   - Edge case handling for auctions
   - Reentrancy protection for all external functions

5. **Storage Considerations:**
   - All storage defined directly in the contract
   - New variables appended to maintain upgradeability
   - Clear separation between standard and Merkle auction storage 