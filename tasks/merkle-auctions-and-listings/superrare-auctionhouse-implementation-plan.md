# SuperRare Auction House V2 Implementation Plan

## Implementation Status
**Current Status:** Phase 1 completed. Ready to begin Phase 2 (Logic Implementation).

**Completed:**
- Initial V2 directory structure and contract skeletons
- Interface definition
- Storage variable definition
- Implementation analysis
- ETH fallback guard implementation
- Test file structure

**Next Steps:**
- Copy and adapt Merkle auction logic with MarketUtilsV2 integration
- Migrate and adapt standard auction functionality
- Implement exclusivity guards between standard and Merkle auctions

## 1. Overview

This document outlines the plan to create a **new** `SuperRareAuctionHouseV2` contract, intended to become the canonical auction house for SuperRare. This new contract will consolidate standard auction functionality (migrated from the SuperRare Bazaar) with the existing Merkle auction features (copied from the current `SuperRareAuctionHouse`), ensuring full adoption of `MarketUtilsV2`.

**Note:** This plan involves creating a **new contract** (`SuperRareAuctionHouseV2.sol`) within a `v2` directory structure, rather than modifying the existing `src/auctionhouse/SuperRareAuctionHouse.sol`. The existing contract will eventually be superseded.

## 2. Core Objectives

*   **Create New V2 Contract:** Implement `src/v2/auctionhouse/SuperRareAuctionHouseV2.sol`.
*   **Consolidate Standard Auctions:** Migrate relevant standard auction functionalities (create, bid, cancel, settle) from `src/bazaar/SuperRareBazaar.sol` (or its base contracts) into the new V2 contract.
*   **Integrate Merkle Auctions:** Copy and integrate the existing Merkle auction logic (`registerAuctionMerkleRoot`, `bidWithAuctionMerkleProof`, etc.) from `src/auctionhouse/SuperRareAuctionHouse.sol` into the new V2 contract.
*   **Adopt MarketUtilsV2:** Ensure all market interactions (fee calculation, payouts, approvals) within the new V2 contract use `src/utils/v2/MarketUtilsV2.sol`.
*   **Self-Contained Storage:** Define and manage all necessary state variables directly within `SuperRareAuctionHouseV2.sol`.
*   **Remove Deprecated Logic:** Do not migrate `convertOfferToAuction` logic.
*   **Test-Driven Development:** Write comprehensive tests for all logic within the new V2 contract, potentially adapting existing Merkle tests.

## 3. Proposed Structure & Changes

*   **Target Contract:** `src/v2/auctionhouse/SuperRareAuctionHouseV2.sol` (New file)
    *   This contract will contain consolidated standard and Merkle auction logic, use `MarketUtilsV2`, and manage its own storage.
*   **Key Utility:** `src/utils/v2/MarketUtilsV2.sol`
    *   All fee calculations, payouts, and market interactions must go through this library.
*   **Source Contract (Standard Auctions):** `src/bazaar/SuperRareBazaar.sol` (and potentially `SuperRareBazaarBase.sol`)
    *   Identify and copy relevant functions/logic related to standard auctions.
*   **Source Contract (Merkle Auctions):** `src/auctionhouse/SuperRareAuctionHouse.sol`
    *   Identify and copy relevant functions, events, and storage definitions related to Merkle auctions.
*   **Storage:** Defined directly within `SuperRareAuctionHouseV2.sol`.
    *   The V2 contract will manage its own state variables internally.
    *   **Upgradeability Note:** As this contract might be upgradeable, new state variables must be appended at the end of the variable declarations to maintain storage layout compatibility for proxies (UUPS, Transparent).
*   **Interfaces:** `src/v2/auctionhouse/ISuperRareAuctionHouseV2.sol` (New file)
    *   Define the interface for the new V2 contract, including both standard and Merkle auction functions.
*   **Tests:** `src/test/v2/auctionhouse/` (New directory)
    *   Create new test files (e.g., `SuperRareAuctionHouseV2Standard.t.sol`, `SuperRareAuctionHouseV2Merkle.t.sol`) for the V2 contract.

## 4. Contracts/Modules Analysis

*   **To Be Created:**
    *   `src/v2/auctionhouse/SuperRareAuctionHouseV2.sol`: The main V2 contract.
    *   `src/v2/auctionhouse/ISuperRareAuctionHouseV2.sol`: The V2 interface.
    *   New test files under `src/test/v2/auctionhouse/` (e.g., `SuperRareAuctionHouseV2Standard.t.sol`, `SuperRareAuctionHouseV2Merkle.t.sol`).
*   **To Be Referenced/Used:**
    *   `src/utils/v2/MarketUtilsV2.sol`: Core utility for market operations.
    *   `src/bazaar/SuperRareBazaar.sol` / `SuperRareBazaarBase.sol`: Source for migrating standard auction logic.
    *   `src/auctionhouse/SuperRareAuctionHouse.sol`: Source for copying Merkle auction logic.
    *   `src/test/auctionhouse/SuperRareAuctionHouseMerkle.t.sol`: Source for adapting Merkle auction tests.
*   **To Be Ignored/Removed (Functionality):**
    *   `convertOfferToAuction` logic from Bazaar/original AuctionHouse.
    *   Auction logic remaining *only* in `SuperRareBazaar.sol` after migration.
*   **To Be Deprecated/Superseded:**
    *   `src/auctionhouse/SuperRareAuctionHouse.sol` and `src/auctionhouse/ISuperRareAuctionHouse.sol`.

## 5. Implementation Task Checklist

**Phase 1: Setup & Initial V2 Contract Structure**

1.  **[x] Create V2 Directory Structure:** Create `src/v2/auctionhouse/` and `src/test/v2/auctionhouse/`.
2.  **[x] Create Initial `SuperRareAuctionHouseV2.sol`:** Set up the basic contract structure (imports, OwnableUpgradeable, ReentrancyGuardUpgradeable, inherits V2 interface).
3.  **[x] Create `ISuperRareAuctionHouseV2.sol`:** Define initial interface structure.
4.  **[x] Analyze `SuperRareBazaar.sol` / `SuperRareBazaarBase.sol`:** Identify standard auction functions, events, and storage needs for migration.
5.  **[x] Analyze `SuperRareAuctionHouse.sol`:** Identify Merkle auction functions, events, and storage needs for copying.
6.  **[x] Define Internal Storage for `SuperRareAuctionHouseV2.sol`:** Based on analysis (Tasks 4 & 5), define the required internal storage variables (mappings, structs) within `SuperRareAuctionHouseV2.sol`, respecting upgradeability rules.
7.  **[x] Create Implementation Analysis Document:** Document findings and create a detailed analysis of required components, storage, and functionality for reference during implementation phases.
8.  **[x] Create Test File Skeletons:** Create basic structure for test files (`SuperRareAuctionHouseV2Standard.t.sol` and `SuperRareAuctionHouseV2Merkle.t.sol`).

**Phase 1 Summary:** All Phase 1 tasks have been completed. The initial structure for the V2 contract has been set up including directory structure, interface definition, and implementation skeleton. Storage variables have been defined based on the analysis of existing contracts. The ETH fallback guard has also been implemented. Test file skeletons are in place, and a comprehensive implementation analysis document has been created to guide the implementation in subsequent phases.

**Phase 2: Logic Implementation (Standard & Merkle)**

9.  **[ ] Copy & Adapt Merkle Auction Logic:**
    *   Copy relevant functions (`registerAuctionMerkleRoot`, `bidWithAuctionMerkleProof`, `cancelAuctionMerkleRoot`, getters, etc.), events, and structs from `src/auctionhouse/SuperRareAuctionHouse.sol` to `SuperRareAuctionHouseV2.sol`.
    *   Adapt storage interactions to use the internally defined V2 variables (Task 6).
    *   **Refactor copied Merkle logic to use `MarketUtilsV2`** for fees, payments, approvals, etc.
10. **[ ] Copy & Adapt Standard Auction Logic (`configureAuction`):**
    *   Migrate `configureAuction` logic from Bazaar to `SuperRareAuctionHouseV2.sol`.
    *   Ensure it uses `MarketUtilsV2`.
    *   Adapt storage interactions to use internal V2 variables.
    *   Implement exclusivity guards (Task 7).
11. **[ ] Copy & Adapt Standard Auction Logic (`bid`):**
    *   Migrate `bid` logic from Bazaar to `SuperRareAuctionHouseV2.sol`.
    *   Ensure full `MarketUtilsV2` integration.
    *   Adapt storage interactions.
    *   Implement exclusivity guards.
12. **[ ] Copy & Adapt Standard Auction Logic (`cancelAuction`):**
    *   Migrate `cancelAuction` logic from Bazaar to `SuperRareAuctionHouseV2.sol`.
    *   **Refine Permissions:** Default to `msg.sender == auctionCreator`. Decide on `tokenOwner`/curator roles.
    *   Adapt storage interactions.
13. **[ ] Copy & Adapt Standard Auction Logic (`settleAuction`):**
    *   Migrate `settleAuction` logic from Bazaar to `SuperRareAuctionHouseV2.sol`.
    *   Ensure payout uses `MarketUtilsV2._handlePayout`.
    *   Adapt storage interactions and NFT transfer logic.
14. **[ ] Harmonize Structs & Events in V2:** Review and standardize structs (`Auction`, `Bid`, etc.) and events across standard and Merkle flows within `SuperRareAuctionHouseV2.sol` and `ISuperRareAuctionHouseV2.sol`. Aim for consistent naming and parameters.
15. **[ ] Update `ISuperRareAuctionHouseV2.sol`:** Finalize the V2 interface with all public/external function signatures and event definitions.

**Phase 3: Testing**

16. **[ ] Write/Adapt Tests for Merkle Logic (`SuperRareAuctionHouseV2Merkle.t.sol`):**
    *   Copy tests from `src/test/auctionhouse/SuperRareAuctionHouseMerkle.t.sol`.
    *   Adapt tests to target `SuperRareAuctionHouseV2.sol` and use `MarketUtilsV2` setups.
    *   Ensure `tokenAuctionNonce` logic is thoroughly tested.
17. **[ ] Write Tests for Standard `configureAuction` (`SuperRareAuctionHouseV2Standard.t.sol`):** Cover scenarios, permissions, exclusivity checks for the V2 implementation.
18. **[ ] Write Tests for Standard `bid` (`SuperRareAuctionHouseV2Standard.t.sol`):** Cover bidding logic, `MarketUtilsV2` integration, exclusivity checks for V2.
19. **[ ] Write Tests for Standard `cancelAuction` (`SuperRareAuctionHouseV2Standard.t.sol`):** Cover refined permissions, timing, state changes for V2.
20. **[ ] Write Tests for Standard `settleAuction` (`SuperRareAuctionHouseV2Standard.t.sol`):** Cover settlement logic, `MarketUtilsV2` payouts, token transfer for V2.
21. **[ ] Add Interaction & Exclusivity Tests (`SuperRareAuctionHouseV2*.t.sol`):** Explicitly test interactions and exclusivity rules between standard and Merkle flows in the V2 contract.
22. **[ ] Perform Gas Benchmarking:** Run gas benchmarks for key V2 functions.

**Phase 4: Cleanup & Review**

23. **[ ] Code Review:** Perform a thorough review of `SuperRareAuctionHouseV2.sol`, `ISuperRareAuctionHouseV2.sol`, and tests. Focus on correctness, `MarketUtilsV2` integration, security, gas efficiency, event consistency, storage layout, and adherence to the plan.
24. **[x] Add Fallback ETH Guard:** Implement `receive()`/`fallback()` guard in `SuperRareAuctionHouseV2.sol`.
25. **[ ] Document State Transitions:** Document the V2 auction states (`Configured`, `Running`, `Unsettled`, Cleared).

## 6. Testing Strategy

*   **V2 Contract Logic:** Implement comprehensive unit and integration tests using Foundry for *all* functions (standard and Merkle) within `SuperRareAuctionHouseV2.sol`. Adapt existing Merkle tests where possible.
*   **Focus Areas:** Edge cases, permissions, `MarketUtilsV2` integration, exclusivity rules, event emission, state transitions, Merkle replay protection (`tokenAuctionNonce`).
*   **Excluded Logic:** Do *not* test deprecated Bazaar functions or the original `src/auctionhouse/SuperRareAuctionHouse.sol`.

## 7. Open Questions

*   **Curator Cancellation:** Define final permissions for `cancelAuction` in V2 (creator only, owner, specific roles?).
*   **Auction Exclusivity:** Confirm mutual exclusivity approach for V2 implementation.
*   **Access Control:** Are roles beyond `Ownable` needed for V2 (admin, pauser)?
*   **Upgradeability:** Confirm V2 contract is intended to be upgradeable and ensure storage rules are strictly followed.
*   **Naming:** Finalize naming for V2 contract (`SuperRareAuctionHouseV2.sol`?) and interface.

## 8. Potential Optimizations & Considerations

*   **Gas Optimization:** Review V2 storage, calldata, `MarketUtilsV2` usage.
*   **Modularity:** Consider internal libraries for shared logic within V2.
*   **Security Hardening:** Apply all previous points (reentrancy, access control, input validation, ownership checks, Merkle proof/nonce, fallback guard) to the new V2 contract. Strictly follow storage layout rules for upgradeability.

