# Merkle Auctions Implementation Plan

## Phase 1: Storage Updates

### 1. Base Storage Updates (SuperRareBazaarBase.sol)
- [ ] Add Merkle-specific storage mappings
  - [ ] `mapping(address => EnumerableSet.Bytes32Set) private _userAuctionMerkleRoots` // For tracking and querying all roots per user
  - [ ] `mapping(address => mapping(bytes32 => uint256)) public auctionMerkleRootNonce` // For versioning
  - [ ] `mapping(address => mapping(bytes32 => mapping(uint256 => MerkleAuctionConfig))) public auctionMerkleConfigs` // For config storage
  - [ ] `mapping(bytes32 => bool) public auctionMerkleProofUsed` // For replay protection

### 2. Struct Updates
- [ ] Add `MerkleAuctionConfig` struct to SuperRareBazaarBase.sol
- [ ] Update existing storage layout documentation

## Phase 2: Interface Updates

### 1. ISuperRareAuctionHouse.sol Updates
- [ ] Add new function signatures
  - [ ] `registerAuctionMerkleRoot`
  - [ ] `cancelAuctionMerkleRoot`
  - [ ] `bidWithAuctionMerkleProof`
  - [ ] `getUserAuctionMerkleRoots`
  - [ ] `getCurrentAuctionMerkleRootNonce`
  - [ ] `isTokenInRoot`
- [ ] Add NatSpec documentation for new functions

## Phase 3: Function Shells

### 1. Root Management Shells
- [ ] Implement empty `registerAuctionMerkleRoot` function
  ```solidity
  function registerAuctionMerkleRoot(
    bytes32 merkleRoot,
    MerkleAuctionConfig calldata config
  ) external {
    // TODO: Implement
  }
  ```
- [ ] Implement empty `cancelAuctionMerkleRoot` function
  ```solidity
  function cancelAuctionMerkleRoot(bytes32 root) external {
    // TODO: Implement
  }
  ```

### 2. Bidding System Shells
- [ ] Implement empty `bidWithAuctionMerkleProof` function
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
    // TODO: Implement
  }
  ```

### 3. View Function Shells
- [ ] Implement empty `getUserAuctionMerkleRoots` function
  ```solidity
  function getUserAuctionMerkleRoots(address user) external view returns (bytes32[] memory) {
    // TODO: Implement
  }
  ```
- [ ] Implement empty `getCurrentAuctionMerkleRootNonce` function
  ```solidity
  function getCurrentAuctionMerkleRootNonce(address user, bytes32 root) external view returns (uint256) {
    // TODO: Implement
  }
  ```
- [ ] Implement empty `isTokenInRoot` function
  ```solidity
  function isTokenInRoot(bytes32 root, address origin, uint256 tokenId, bytes32[] calldata proof) public pure returns (bool) {
    // TODO: Implement
  }
  ```

## Phase 4: Test Implementation

### 1. Test Setup
- [ ] Create `MerkleAuctionHouse.t.sol`
- [ ] Set up test environment
- [ ] Create helper functions
- [ ] Create mock contracts

### 2. Root Management Tests
- [ ] Test `registerAuctionMerkleRoot`
  - [ ] Test valid registration
  - [ ] Test invalid config parameters
  - [ ] Test nonce increment
  - [ ] Test root added to EnumerableSet
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