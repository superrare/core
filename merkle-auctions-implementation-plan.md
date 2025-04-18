# Merkle Auctions Implementation Plan

## Phase 1: Storage Updates

### 1. Base Storage Updates (SuperRareBazaarBase.sol)
- [x] Add Merkle-specific storage mappings
  - [x] `mapping(address => EnumerableSet.Bytes32Set) private _userAuctionMerkleRoots` // For tracking and querying all roots per user
  - [x] `mapping(address => mapping(bytes32 => uint256)) public auctionMerkleRootNonce` // For versioning
  - [x] `mapping(address => mapping(bytes32 => mapping(uint256 => MerkleAuctionConfig))) public auctionMerkleConfigs` // For config storage
  - [x] `mapping(bytes32 => bool) public auctionMerkleProofUsed` // For replay protection

### 2. Struct Updates
- [x] Add `MerkleAuctionConfig` struct to SuperRareBazaarBase.sol
  - [x] Added fields: currency, startingAmount, duration, splitAddresses, splitRatios
- [x] Update existing storage layout documentation
  - [x] Added storage section for Merkle Auction Storage
  - [x] Added EnumerableSet import and usage

## Phase 2: Interface Updates

### 1. ISuperRareAuctionHouse.sol Updates
- [x] Add new function signatures
  - [x] `registerAuctionMerkleRoot`
  - [x] `cancelAuctionMerkleRoot`
  - [x] `bidWithAuctionMerkleProof`
  - [x] `getUserAuctionMerkleRoots`
  - [x] `getCurrentAuctionMerkleRootNonce`
  - [x] `isTokenInRoot`
- [x] Add NatSpec documentation for new functions
  - [x] Added detailed parameter descriptions
  - [x] Added return value descriptions
  - [x] Added function purpose descriptions

## Phase 3: Function Shells

### 1. Root Management Shells
- [x] Implement empty `registerAuctionMerkleRoot` function
  ```solidity
  function registerAuctionMerkleRoot(
    bytes32 merkleRoot,
    MerkleAuctionConfig calldata config
  ) external {
    revert("registerAuctionMerkleRoot::Not implemented");
  }
  ```
- [x] Implement empty `cancelAuctionMerkleRoot` function
  ```solidity
  function cancelAuctionMerkleRoot(bytes32 root) external {
    revert("cancelAuctionMerkleRoot::Not implemented");
  }
  ```

### 2. Bidding System Shells
- [x] Implement empty `bidWithAuctionMerkleProof` function
  ```solidity
  function bidWithAuctionMerkleProof(
    address originContract,
    uint256 tokenId,
    address creator,
    bytes32 merkleRoot,
    address currency,
    uint256 bidAmount,
    bytes32[] calldata proof
  ) external payable nonReentrant {
    revert("bidWithAuctionMerkleProof::Not implemented");
  }
  ```

### 3. View Function Shells
- [x] Implement empty `getUserAuctionMerkleRoots` function
  ```solidity
  function getUserAuctionMerkleRoots(address user) external view returns (bytes32[] memory) {
    revert("getUserAuctionMerkleRoots::Not implemented");
  }
  ```
- [x] Implement empty `getCurrentAuctionMerkleRootNonce` function
  ```solidity
  function getCurrentAuctionMerkleRootNonce(address user, bytes32 root) external view returns (uint256) {
    revert("getCurrentAuctionMerkleRootNonce::Not implemented");
  }
  ```
- [x] Implement empty `isTokenInRoot` function
  ```solidity
  function isTokenInRoot(bytes32 root, address origin, uint256 tokenId, bytes32[] calldata proof) public pure returns (bool) {
    revert("isTokenInRoot::Not implemented");
  }
  ```

## Phase 4: Test Implementation

### 1. Test Setup
- [x] Add Merkle auction tests to `SuperRareAuctionHouse.t.sol`
- [x] Set up test environment
  - [x] Created TestNFT and TestToken contracts
  - [x] Set up Merkle tree generation
  - [x] Created test users and funding
- [x] Create helper functions for Merkle proof generation
- [x] Create mock contracts for testing

### 2. Root Management Tests
- [x] Test `registerAuctionMerkleRoot`
  - [x] Test valid registration
  - [x] Test nonce increment
  - [x] Test root added to EnumerableSet
  - [ ] Test event emission
- [ ] Test `cancelAuctionMerkleRoot`
  - [ ] Test valid cancellation
  - [ ] Test invalid cancellation attempts
  - [ ] Test root removed from EnumerableSet
  - [ ] Test data cleanup
  - [ ] Test event emission

### 3. Bidding System Tests
- [ ] Test `bidWithAuctionMerkleProof`
  - [ ] Test valid proofs
  - [ ] Test invalid proofs
  - [ ] Test replay protection
  - [ ] Test ownership verification
  - [ ] Test approval checks
  - [ ] Test token transfer
  - [ ] Test auction creation
  - [ ] Test event emission

### 4. View Function Tests
- [ ] Test `getUserAuctionMerkleRoots`
  - [ ] Test with no roots
  - [ ] Test with multiple roots
- [ ] Test `getCurrentAuctionMerkleRootNonce`
  - [ ] Test initial nonce
  - [ ] Test after registration
- [ ] Test `isTokenInRoot`
  - [ ] Test valid proofs
  - [ ] Test invalid proofs

## Phase 5: Function Implementation

### 1. Root Management Implementation
- [ ] Implement `registerAuctionMerkleRoot`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests
- [ ] Implement `cancelAuctionMerkleRoot`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests

### 2. Bidding System Implementation
- [ ] Implement `bidWithAuctionMerkleProof`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests

### 3. View Function Implementation
- [ ] Implement `getUserAuctionMerkleRoots`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests
- [ ] Implement `getCurrentAuctionMerkleRootNonce`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests
- [ ] Implement `isTokenInRoot`
  - [ ] Run tests after each component
  - [ ] Fix any failing tests

## Phase 6: Gas Optimization

### 1. Storage Optimization
- [ ] Review and optimize storage mappings
- [ ] Optimize proof key generation
- [ ] Review gas usage in critical functions

### 2. Function Optimization
- [ ] Optimize loop operations
- [ ] Implement batch operations where possible
- [ ] Review gas costs against existing functions

## Phase 7: Documentation

### 1. Code Documentation
- [ ] Update NatSpec comments for new functions
- [ ] Document security considerations
- [ ] Add usage examples

### 2. External Documentation
- [ ] Update README with new functionality
- [ ] Document security best practices
- [ ] Add integration examples

## Phase 8: Security Review

### 1. Internal Review
- [ ] Review all access controls
- [ ] Verify reentrancy protection
- [ ] Check for potential race conditions
- [ ] Review error handling

### 2. External Review
- [ ] Schedule security audit
- [ ] Address audit findings
- [ ] Implement recommended fixes

## Phase 9: Deployment

### 1. Preparation
- [ ] Update deployment scripts
- [ ] Set up verification process
- [ ] Prepare upgrade strategy

### 2. Execution
- [ ] Deploy to testnet
- [ ] Verify functionality
- [ ] Deploy to mainnet
- [ ] Monitor initial usage 