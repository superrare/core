# SuperRare Auction House Implementation Plan

## 1. Overview

This document outlines the plan to consolidate auction functionality into the `SuperRareAuctionHouse` contract (`src/auctionhouse/SuperRareAuctionHouse.sol`), migrating necessary logic from the SuperRare Bazaar (`src/bazaar/SuperRareBazaar.sol`), integrating existing Merkle auction features, and ensuring full adoption of `MarketUtilsV2` (`src/utils/v2/MarketUtilsV2.sol`). The goal is to create a single, canonical auction contract for SuperRare, eventually replacing the auction capabilities of the Bazaar.

**Note:** This plan involves modifying and extending the *existing* `SuperRareAuctionHouse.sol` contract, rather than creating a completely new one from scratch, as it already contains the required Merkle auction logic and tests.

## 2. Core Objectives

*   **Consolidate Auction Logic:** Migrate standard auction functionalities (create, bid, cancel, settle) from `SuperRareBazaar.sol` (or its base contracts) into `v2/SuperRareAuctionHouse.sol`.
*   **Integrate Merkle Auctions:** Ensure the existing Merkle auction logic (`registerAuctionMerkleRoot`, `bidWithAuctionMerkleProof`) coexists seamlessly with standard auctions.
*   **Adopt MarketUtilsV2:** Refactor all market interactions (fee calculation, payouts, approvals) within `SuperRareAuctionHouse.sol` to use `MarketUtilsV2`.
*   **Remove Deprecated Logic:** Ensure functionality like `convertOfferToAuction` remains deprecated or is fully removed.
*   **Test-Driven Development:** Write tests for all *newly migrated or refactored* logic. Leverage existing tests for Merkle auctions. Do *not* migrate tests for old Bazaar auction logic.

## 3. Proposed Structure & Changes

*   **Target Contract:** `src/auctionhouse/SuperRareAuctionHouse.sol`
    *   This contract will be the primary focus, receiving migrated logic and updates.
*   **Key Utility:** `src/utils/v2/MarketUtilsV2.sol`
    *   All fee calculations, payouts, and market interactions must go through this library.
*   **Source Contract (for Migration):** `src/bazaar/SuperRareBazaar.sol` (and potentially `SuperRareBazaarBase.sol`)
    *   Identify and copy relevant functions/logic related to standard auctions.
*   **Storage:** `src/bazaar/SuperRareBazaarStorage.sol`
    *   Review if any storage variables related to standard auctions need to be migrated or adapted within `SuperRareAuctionHouse.sol`. Consider if a dedicated `SuperRareAuctionHouseStorage.sol` is beneficial for clarity, although modifying the existing `SuperRareBazaarStorage` might be simpler if dependencies allow. (Needs further investigation during implementation).
*   **Interfaces:** `src/auctionhouse/ISuperRareAuctionHouse.sol`
    *   Update this interface to reflect the consolidated functionality (standard + Merkle auctions).
*   **Tests:** `src/test/auctionhouse/`
    *   Create new test files (e.g., `SuperRareAuctionHouseStandard.t.sol`) for the migrated standard auction logic.
    *   Leverage existing `SuperRareAuctionHouseMerkle.t.sol` for Merkle logic.

## 4. Contracts/Modules Analysis

*   **To Be Modified/Extended:**
    *   `src/auctionhouse/SuperRareAuctionHouse.sol`: Add standard auction logic, refactor to `MarketUtilsV2`.
    *   `src/auctionhouse/ISuperRareAuctionHouse.sol`: Update interface definitions.
    *   `src/bazaar/SuperRareBazaarStorage.sol`: Potentially add/modify storage slots if not creating a separate storage contract.
*   **To Be Referenced/Used:**
    *   `src/utils/v2/MarketUtilsV2.sol`: Core utility for market operations.
    *   `src/bazaar/SuperRareBazaar.sol` / `SuperRareBazaarBase.sol`: Source for migrating standard auction logic.
*   **To Be Created:**
    *   New test files under `src/test/auctionhouse/` for standard auction functionality.
*   **To Be Ignored/Removed (Functionality):**
    *   `convertOfferToAuction` logic (already marked deprecated).
    *   Any auction logic remaining *only* in `SuperRareBazaar.sol` after migration.
    *   Tests related to the old Bazaar auction implementation.

## 5. Implementation Task Checklist

**Phase 1: Setup & Refactoring**

1.  **[ ] Analyze `SuperRareBazaar.sol` / `SuperRareBazaarBase.sol`:** Identify exact functions, events, and storage related to standard auctions (`configureAuction`, `bid`, `cancelAuction`, `settleAuction`, associated events/structs).
2.  **[ ] Analyze `SuperRareBazaarStorage.sol`:** Determine which auction-related storage variables are needed in the consolidated `SuperRareAuctionHouse`. Decide on storage strategy (modify existing vs. new contract).
3.  **[ ] Refactor `SuperRareAuctionHouse.sol` - `MarketUtilsV2` Integration:**
    *   Replace all instances of fee calculation (e.g., `marketplaceSettings.calculateMarketplaceFee`) with `MarketUtilsV2.calculateFee`.
    *   Refactor payout logic (e.g., `_payout`, `_refund`) to use `MarketUtilsV2` functions (e.g., `_handlePayment`, `_handlePayout`).
    *   Update currency/payment checks (`_checkIfCurrencyIsApproved`, `_checkAmountAndTransfer`) to align with `MarketUtilsV2` methods if applicable.
    *   Ensure marketplace approval checks (`_senderMustHaveMarketplaceApproved`, `_ownerMustHaveMarketplaceApprovedForNFT`) are compatible or replaced by `MarketUtilsV2` equivalents if available.
4.  **[ ] Update `ISuperRareAuctionHouse.sol`:** Add function signatures for standard auctions (`configureAuction`, `bid`, `cancelAuction`, `settleAuction`) and any associated events/structs identified in step 1.

**Phase 2: Standard Auction Logic Migration**

5.  **[ ] Copy & Adapt `configureAuction`:**
    *   Migrate `configureAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure it uses `MarketUtilsV2` for any relevant checks/interactions.
    *   Adapt storage interactions based on the decided storage strategy.
    *   Verify compatibility with existing Merkle logic (no conflicts in state/functionality).
6.  **[ ] Copy & Adapt `bid`:**
    *   Migrate `bid` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure full `MarketUtilsV2` integration (fee calculation, payment handling, refunds).
    *   Adapt storage.
    *   Ensure correct event emission.
7.  **[ ] Copy & Adapt `cancelAuction`:**
    *   Migrate `cancelAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Adapt storage.
    *   Ensure correct event emission.
8.  **[ ] Copy & Adapt `settleAuction`:**
    *   Migrate `settleAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure payout uses `MarketUtilsV2._handlePayout`.
    *   Adapt storage and NFT transfer logic.
    *   Ensure correct event emission.
9.  **[ ] Migrate Auction Structs & Events:** Copy relevant structs (like `Auction`, `Bid` if different from existing ones) and events (`NewAuction`, `AuctionBid`, `CancelAuction`, `AuctionSettled`) from Bazaar/Storage/Interfaces to `SuperRareAuctionHouse.sol` or its interface/storage as appropriate. Ensure no naming conflicts.

**Phase 3: Testing**

10. **[ ] Write Tests for `configureAuction`:** Create tests in a new file (e.g., `SuperRareAuctionHouseStandard.t.sol`) covering various scenarios (coldie, scheduled, valid/invalid inputs, permissions).
11. **[ ] Write Tests for `bid`:** Add tests covering bidding logic (first bid, subsequent bids, minimum increase, currency validation, end-of-auction extension, `MarketUtilsV2` integration).
12. **[ ] Write Tests for `cancelAuction`:** Add tests covering cancellation logic (permissions, timing constraints, state changes).
13. **[ ] Write Tests for `settleAuction`:** Add tests covering settlement logic (auction ended, winner payout via `MarketUtilsV2`, token transfer, no-bidder scenario).
14. **[ ] Review Existing Merkle Tests:** Ensure `SuperRareAuctionHouseMerkle.t.sol` still passes after refactoring and adding standard auction logic. Add interaction tests if necessary (e.g., ensure a standard bid can't happen on a Merkle-initiated auction and vice-versa, unless intended).

**Phase 4: Cleanup & Review**

15. **[ ] Code Review:** Perform a thorough review focusing on `MarketUtilsV2` integration, security (reentrancy, access control), correctness, gas efficiency, and adherence to the plan.
16. **[ ] Remove Redundant Bazaar Logic:** Once confident in the `SuperRareAuctionHouse` implementation, identify and mark for removal (or comment out initially) the now-redundant auction logic within `SuperRareBazaar.sol`.
17. **[ ] Documentation:** Update any relevant documentation (READMEs, NatSpec comments) to reflect the consolidated auction house.

## 6. Testing Strategy

*   **New Logic (Standard Auctions):** Implement comprehensive unit and integration tests using Foundry for all migrated functions (`configureAuction`, `bid`, `cancelAuction`, `settleAuction`) and their interactions within `SuperRareAuctionHouse.sol`. Focus on edge cases, permissions, and correct integration with `MarketUtilsV2`.
*   **Existing Logic (Merkle Auctions):** Rely on the existing tests in `src/test/auctionhouse/SuperRareAuctionHouseMerkle.t.sol`. Verify these tests continue to pass after the refactoring. Add minimal integration tests if standard/Merkle interactions need specific verification.
*   **Excluded Logic:** Do *not* migrate or write tests for the deprecated `convertOfferToAuction` function or the original auction implementation within `SuperRareBazaar.sol`.

## 7. Open Questions

*   **Storage Strategy:** Should auction-related state remain in `SuperRareBazaarStorage.sol` (potentially renamed or refactored), or should a new, dedicated `SuperRareAuctionHouseStorage.sol` be created? Using the existing storage might simplify state management but could tightly couple the Auction House to the Bazaar's storage structure.
*   **Curator Cancellation:** The original plan asked about curator cancellation. The `cancelAuction` logic identified seems to rely on `msg.sender == auctionCreator` or `msg.sender == tokenOwner`. Should specific curator roles/permissions be added for cancellation?
*   **Fallback Function:** Does the `SuperRareAuctionHouse` require specific `receive()` or `fallback()` logic for ETH handling, or is this sufficiently covered by explicit functions like `bid`? (Assume explicit functions are sufficient unless otherwise specified).
*   **Event Naming/Consistency:** Review event names (`NewAuction` vs. `AuctionMerkleBid`, etc.) for consistency across standard and Merkle auctions. Should they be harmonized?
*   **Access Control:** Beyond `OwnableUpgradeable` and basic sender checks, are there other roles (e.g., admin, pauser) required for managing the auction house functions or settings?

## 8. Potential Optimizations & Considerations

*   **Gas Optimization:**
    *   Review storage reads/writes in auction lifecycle functions. Minimize redundant SLOAD/SSTORE operations.
    *   Analyze calldata usage, especially for `configureAuction` and Merkle proofs.
    *   Ensure `MarketUtilsV2` usage is efficient.
*   **Modularity:**
    *   Consider if further logic abstraction into internal libraries is beneficial, especially if standard and Merkle auctions share common validation or state transition logic.
    *   Evaluate the chosen storage strategy's impact on modularity.
*   **Security Hardening:**
    *   Ensure robust reentrancy guards (`nonReentrant`) on all functions involving external calls or state changes after interactions (bids, settlements).
    *   Double-check access control modifiers on all functions.
    *   Validate all external inputs thoroughly (amounts, addresses, timestamps, splits).
    *   Verify correct NFT ownership and approval checks throughout the auction lifecycle.
    *   Ensure Merkle proof verification and replay protection (`tokenAuctionNonce`) are correctly implemented and tested.

