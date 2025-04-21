# 🧠 Implementation Strategy Request for SuperRare Auction House

## 📦 Overview

We're creating a new `SuperRareAuctionHouse` contract to **replace the auction functionality** currently implemented in the **SuperRare Bazaar**.

The new auction house will:

- Integrate **Merkle root-based auctions** (already implemented and tested).
- Support new auction features (e.g. upgraded logic from the Bazaar, minus deprecated functionality).
- Migrate and clean up code from the old auction system.
- Switch to using **MarketUtilsV2**.
- Be implemented **test-first**, with **explicit outlines of logic and responsibilities**.
- Avoid testing old auction logic again.
- Remove features like `convertOfferToAuction()` (legacy paths).
- Become the new canonical auction house contract for SuperRare.

## ✅ My Goals for You

1. **Read the codebase deeply** – understand which modules need to be copied over, what should be refactored or removed.
2. **Identify and outline all the changes** required to spin up the new `SuperRareAuctionHouse`.
3. **Propose a full implementation plan**:
   - Suggested folder/module structure.
   - New contracts, interfaces, and libraries required.
   - Contracts that should be removed/ignored.
   - Enum/function/struct name changes if needed.
4. **Write a checklist of tasks** with explicit action items (like “copy `createAuction` but refactor to use `MarketUtilsV2.calculateFee`”, etc.)
5. **Ensure everything is test-driven**:
   - For all *new* logic, define how it will be tested.
   - For *existing* logic (Merkle auction), note that it is already covered.
   - Skip test migration for old Bazaar auction logic.
6. **Raise any open questions** (e.g. “should this still support auction cancellation via curator?”, “do you want fallback functions?”, etc.)
7. Make sure we **don’t implement anything yet**—this is a pure planning and analysis pass.

## 🧰 Key Constraints

- We will **not** re-test or refactor the old auction logic.
- We will **not** use `convertOfferToAuction` at all.
- We **will** adopt `MarketUtilsV2` throughout the new contract.
- The new auction house will **live alongside** the existing Bazaar contract, but serve as its **eventual replacement**.

## ✨ Bonus

You should surface and annotate **gas optimization**, **modularity**, and **security hardening** opportunities during the planning phase—especially with regards to how MarketUtils is wired, calldata layout for Merkle proofs, etc.
