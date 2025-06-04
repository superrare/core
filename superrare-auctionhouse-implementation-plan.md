## 3. Proposed Structure & Changes

*   **Target Contract:** `src/auctionhouse/SuperRareAuctionHouse.sol`
    *   This contract will be the primary focus, receiving migrated logic and updates.
*   **Key Utility:** `src/utils/v2/MarketUtilsV2.sol`
    *   All fee calculations, payouts, and market interactions must go through this library.
*   **Source Contract (for Migration):** `src/bazaar/SuperRareBazaar.sol` (and potentially `SuperRareBazaarBase.sol`)
    *   Identify and copy relevant functions/logic related to standard auctions.
*   **Storage:** `src/bazaar/SuperRareBazaarStorage.sol` vs. **New `SuperRareAuctionHouseStorage.sol`**
    *   **Recommendation:** Lean towards creating a **dedicated `SuperRareAuctionHouseStorage.sol`** contract. This promotes isolation, clarity, avoids inheriting potentially unused legacy state, and allows the Auction House to evolve independently. While potentially duplicating a few fields initially, the long-term benefits for maintainability and avoiding tight coupling are significant. The final decision can be confirmed during early implementation analysis.
    *   **Upgradeability Note:** If modifying existing storage or creating a new one that inherits, ensure new state variables are appended at the end to maintain storage layout compatibility for proxies (UUPS, Transparent).
*   **Interfaces:** `src/auctionhouse/ISuperRareAuctionHouse.sol`
    *   Update this interface to reflect the consolidated functionality (standard + Merkle auctions).
*   **Tests:** `src/test/auctionhouse/`

*   **To Be Modified/Extended:**
    *   `src/auctionhouse/SuperRareAuctionHouse.sol`: Add standard auction logic, refactor to `MarketUtilsV2`.
    *   `src/auctionhouse/ISuperRareAuctionHouse.sol`: Update interface definitions.
    *   Potentially `src/bazaar/SuperRareBazaarStorage.sol` OR (Recommended) create `SuperRareAuctionHouseStorage.sol`.
*   **To Be Referenced/Used:**
    *   `src/utils/v2/MarketUtilsV2.sol`: Core utility for market operations.

1.  **[ ] Analyze `SuperRareBazaar.sol` / `SuperRareBazaarBase.sol`:** Identify exact functions, events, and storage related to standard auctions (`configureAuction`, `bid`, `cancelAuction`, `settleAuction`, associated events/structs).
2.  **[ ] Decide & Define Storage Strategy:** Finalize whether to use/modify `SuperRareBazaarStorage.sol` or create a dedicated `SuperRareAuctionHouseStorage.sol` (preferred). Define the required storage variables, ensuring upgradeability rules are followed if applicable.
3.  **[ ] Refactor `SuperRareAuctionHouse.sol` - `MarketUtilsV2` Integration:**
    *   Replace all instances of fee calculation (e.g., `marketplaceSettings.calculateMarketplaceFee`) with `MarketUtilsV2.calculateFee`.

4.  **[ ] Update `ISuperRareAuctionHouse.sol`:** Add function signatures for standard auctions (`configureAuction`, `bid`, `cancelAuction`, `settleAuction`) and any associated events/structs. Ensure consistency (see Task 9).
5.  **[ ] Clarify Auction Exclusivity & Implement Guards:** Determine if standard and Merkle auctions can coexist for the same token ID. **Recommendation:** Enforce mutual exclusivity (only one active auction per token). Implement necessary checks (e.g., in `configureAuction` and `bidWithAuctionMerkleProof`) to prevent conflicts.

**Phase 2: Standard Auction Logic Migration**

6.  **[ ] Copy & Adapt `configureAuction`:**
    *   Migrate `configureAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure it uses `MarketUtilsV2` for any relevant checks/interactions.
    *   Adapt storage interactions based on the decided storage strategy.
    *   Verify compatibility with existing Merkle logic (no conflicts in state/functionality, respects exclusivity rule from Task 5).
7.  **[ ] Copy & Adapt `bid`:**
    *   Migrate `bid` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure full `MarketUtilsV2` integration (fee calculation, payment handling, refunds).
    *   Adapt storage.
    *   Ensure correct event emission (consistent naming - see Task 9).
    *   Respect exclusivity rule from Task 5.
8.  **[ ] Copy & Adapt `cancelAuction`:**
    *   Migrate `cancelAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   **Refine Permissions:** Default to requiring `msg.sender == auctionCreator`. Explicitly discuss and decide if `tokenOwner` or specific curator roles should also have cancellation rights (see Open Question).
    *   Adapt storage.
    *   Ensure correct event emission (consistent naming - see Task 9).
9.  **[ ] Copy & Adapt `settleAuction`:**
    *   Migrate `settleAuction` logic from Bazaar to `SuperRareAuctionHouse.sol`.
    *   Ensure payout uses `MarketUtilsV2._handlePayout`.
    *   Adapt storage and NFT transfer logic.
    *   Ensure correct event emission (consistent naming - see Task 9).
10. **[ ] Harmonize Auction Structs & Events:** Review and standardize structs (e.g., `Auction`, `Bid`) and events (`NewAuction` vs `AuctionMerkleBid`, `AuctionBid`, `CancelAuction`, `AuctionSettled`, etc.) across standard and Merkle flows. Aim for consistent naming and parameter patterns (e.g., use a common `AuctionConfigured` event with a flag/parameter).

**Phase 3: Testing**

11. **[ ] Write Tests for `configureAuction`:** Create tests in a new file (e.g., `SuperRareAuctionHouseStandard.t.sol`) covering various scenarios (coldie, scheduled, valid/invalid inputs, permissions, exclusivity checks).
12. **[ ] Write Tests for `bid`:** Add tests covering bidding logic (first bid, subsequent bids, minimum increase, currency validation, end-of-auction extension, `MarketUtilsV2` integration, exclusivity checks).
13. **[ ] Write Tests for `cancelAuction`:** Add tests covering cancellation logic (permissions based on refined rules, timing constraints, state changes).
14. **[ ] Write Tests for `settleAuction`:** Add tests covering settlement logic (auction ended, winner payout via `MarketUtilsV2`, token transfer, no-bidder scenario).
15. **[ ] Review Existing Merkle Tests:** Ensure `SuperRareAuctionHouseMerkle.t.sol` still passes after refactoring and adding standard auction logic.
16. **[ ] Add Interaction & Exclusivity Tests:** Explicitly test interactions between standard and Merkle flows, ensuring exclusivity rules are enforced (e.g., cannot `configureAuction` if Merkle auction started via `bidWithAuctionMerkleProof`, cannot `bid` on Merkle auction, etc.).
17. **[ ] Add `tokenAuctionNonce` Tests:** Write specific tests to ensure the `tokenAuctionNonce` logic (critical for Merkle replay protection) is correctly handled, updated, and cannot be improperly influenced by standard auction flows.
18. **[ ] Perform Gas Benchmarking:** Run gas benchmarks (e.g., using `forge snapshot` or similar tooling on a local fork) for key functions (`configureAuction`, `bid`, `settleAuction`, `bidWithAuctionMerkleProof`, `registerAuctionMerkleRoot`) under realistic scenarios. Record results.

**Phase 4: Cleanup & Review**

19. **[ ] Code Review:** Perform a thorough review focusing on `MarketUtilsV2` integration, security (reentrancy, access control, input validation, fallback guard), correctness, gas efficiency, event consistency, storage layout, and adherence to the plan.
20. **[ ] Add Fallback ETH Guard:** Implement a `receive() external payable { revert("Direct ETH transfers not allowed"); }` (and potentially `fallback()`) to prevent accidental ETH locking.
21. **[ ] Document State Transitions:** Create a simple diagram or document explaining the possible states of an auction (e.g., `NotCreated`, `ConfiguredScheduled`, `Active`, `Ended`, `Settled`) and the functions that trigger transitions.
22. **[ ] Remove Redundant Bazaar Logic:** Once confident in the `SuperRareAuctionHouse` implementation, identify and mark for removal (or comment out initially) the now-redundant auction logic within `SuperRareBazaar.sol`.
23. **[ ] Documentation:** Update any relevant documentation (READMEs, NatSpec comments) to reflect the consolidated auction house, storage strategy, event structure, and state transitions.

*   **Storage Strategy:** As discussed, creating a dedicated `SuperRareAuctionHouseStorage.sol` is preferred for isolation and long-term maintainability, despite potential initial duplication. The impact on upgradeability needs careful management.
*   **Curator Cancellation:** The current logic allows `tokenOwner` cancellation. **Recommendation:** Change default to `creator == msg.sender`. Should specific curator roles/permissions be added for cancellation, especially considering complex ownership (vaults, etc.)? Needs explicit decision.
*   **Auction Exclusivity:** Can a token have both a standard configured auction *and* be part of an active Merkle root simultaneously? **Recommendation:** Enforce mutual exclusivity (one auction active per token ID). Needs implementation.
*   **Fallback Function:** Does the `SuperRareAuctionHouse` require specific `receive()` or `fallback()` logic? **Recommendation:** Yes, add a `revert()`-guarded function to prevent accidental ETH locking (Task 20).
*   **Event Naming/Consistency:** Event names/structures differ between standard (`NewAuction`, `AuctionBid`) and Merkle (`NewAuctionMerkleRoot`, `AuctionMerkleBid`). **Recommendation:** Harmonize these for consistency (Task 10).
*   **Access Control:** Beyond `OwnableUpgradeable` and creator/owner checks, are other roles (e.g., admin, pauser) required?
*   **Upgradeability:** If the contract is intended to be upgradeable, storage layout rules *must* be strictly followed (Task 2 & general awareness).

*   **Security Hardening:**
    *   Ensure robust reentrancy guards (`nonReentrant`) on all functions involving external calls or state changes after interactions (bids, settlements).
    *   Double-check access control modifiers on all functions (including refined cancellation logic).
    *   Validate all external inputs thoroughly (amounts, addresses, timestamps, splits).
    *   Verify correct NFT ownership and approval checks throughout the auction lifecycle.
    *   Ensure Merkle proof verification and replay protection (`tokenAuctionNonce`) are correctly implemented and explicitly tested (Task 17).
    *   Include fallback ETH guard (Task 20).
    *   Consider storage slot collision possibilities if modifying existing storage. 