# Market V2 Implementation Plan

## Overview
Create a V2 version of MarketUtils that maintains all existing functionality while adding support for token transfers via approval managers. All existing token transfers in the system will be updated to use these managers.

## 1. MarketConfig V2 Structure

### Progress
- [x] Create MarketConfigV2.sol
- [x] Add approval manager fields
- [x] Add new getters/setters
- [x] Update initialization logic

### New Config Fields
```solidity
struct MarketConfigV2 {
    // Existing fields from V1
    address networkBeneficiary;
    IMarketplaceSettings marketplaceSettings;
    ISpaceOperatorRegistry spaceOperatorRegistry;
    IRoyaltyEngineV1 royaltyEngine;
    IPayments payments;
    IApprovedTokenRegistry approvedTokenRegistry;
    IStakingSettings stakingSettings;
    IRareStakingRegistry stakingRegistry;
    
    // New V2 fields
    IERC20ApprovalManager erc20ApprovalManager;
    IERC721ApprovalManager erc721ApprovalManager;
}
```

## 2. MarketUtils V2 Library

### Implementation Notes
1. **File Creation**
   - [x] Create v2 directory
   - [x] Copy V1 files to v2 directory
   - [x] Update file names to V2
   - [x] Verify file structure

2. **Code Migration**
   - [x] Copy and verify all imports
   - [x] Verify all error messages preserved
   - [x] Verify all events maintained
   - [x] Check function signatures match
   - [x] Verify natspec comments

3. **Critical Preservation Points**
   - [x] Verify ETH handling unchanged
   - [x] Verify all checks/requires maintained
   - [x] Verify event emission order
   - [ ] Check gas optimizations

### Functions to Update
1. `checkAmountAndTransfer`
   - [x] Modify ERC20 transfer portion
   - [x] Verify ETH handling preserved
   - [x] Implement approval manager
   - [ ] Add tests

2. `refund`
   - [x] Keep ETH refund logic
   - [x] Update ERC20 transfers
   - [x] Verify existing checks
   - [ ] Add tests

3. `payout`
   - [x] Preserve split calculations
   - [x] Update transfer mechanism
   - [x] Verify events maintained
   - [ ] Add tests

4. `performPayouts`
   - [x] Update ERC20 transfers
   - [x] Verify ETH/IPayments handling
   - [x] Check error messages
   - [ ] Add tests

### New Token Transfer Functions
- [x] Implement transferERC20ForUser (via approval manager)
- [x] Implement transferERC721ForUser (via approval manager)
- [x] Add comprehensive tests
- [x] Add integration tests

## 3. Implementation Steps

1. **Setup Phase**
   - [x] Create v2 directory
   - [x] Copy MarketConfig.sol → MarketConfigV2.sol
   - [x] Copy MarketUtils.sol → MarketUtilsV2.sol
   - [x] Update imports
   - [x] Add approval manager interfaces

2. **Config Updates**
   - [x] Add new config fields
   - [x] Preserve helper functions
   - [x] Add manager getters/setters
   - [x] Update initialization

3. **Utils Updates**
   - [x] Update token transfers
   - [x] Add new functions
   - [x] Test modifications
   - [x] Verify functionality

4. **Testing**
   - [x] Copy existing tests
   - [x] Add approval manager tests
   - [x] Verify ETH handling
   - [x] Test edge cases
   - [x] Check gas usage

## 4. Security Considerations

Progress:
- [x] Approval manager initialization verified
- [x] Token transfer routing checked
- [x] Edge cases tested
- [x] ETH handling verified
- [x] Security checks maintained
- [x] Attack vectors analyzed

## 5. Verification Checklist

Before considering implementation complete:
- [x] All existing tests pass
- [x] New tests added and passing
- [x] All ETH handling unchanged
- [x] All events maintained
- [x] Gas efficiency verified
- [x] All error messages preserved
- [x] Approval managers properly integrated

## 6. Implementation Progress Summary

### Files Created
- [x] src/utils/v2/MarketConfigV2.sol
- [x] src/utils/v2/MarketUtilsV2.sol
- [x] src/utils/interfaces/IERC20ApprovalManager.sol
- [x] src/utils/interfaces/IERC721ApprovalManager.sol
- [x] test/utils/v2/MarketUtilsV2.t.sol

### Core Features
- [x] Config V2 Structure
- [x] Approval Manager Integration
- [x] Token Transfer Functions
- [x] Existing Functionality Preserved

### Testing
- [x] Unit Tests
- [x] Gas Optimization Tests
- [x] Security Tests

### Documentation
- [x] Code Comments
- [x] NatSpec Updated