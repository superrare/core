# ERC1155 Token and Marketplace Audit Plan

Last updated: 2026-06-05

## Purpose

This document defines a security audit plan for the RARE Protocol ERC1155 collection system and the ERC1155 marketplace execution stack. It is an audit plan, not a completed audit report. The goal is to give reviewers a precise map of the system, assets at risk, expected invariants, high-risk flows, and verification work required before production deployment or upgrade.

## Primary Scope

Token contracts:

- `src/token/ERC1155/RareERC1155.sol`
- `src/token/ERC1155/IRareERC1155.sol`
- `src/token/ERC1155/RareERC1155ContractFactory.sol`
- `src/token/ERC1155/IRareERC1155ContractFactory.sol`

Marketplace contracts:

- `src/marketplace/RareERC1155Marketplace.sol`
- `src/marketplace/RareERC1155MarketplaceStorage.sol`
- `src/marketplace/RareERC1155ExecutionModuleBase.sol`
- `src/marketplace/RareERC1155TradeExecutionModule.sol`
- `src/marketplace/RareERC1155CheckoutExecutionModule.sol`
- `src/marketplace/RareERC1155MarketplacePayments.sol`
- `src/marketplace/IRareERC1155Marketplace.sol`
- `src/marketplace/IRareERC1155MarketplaceTypes.sol`
- `src/marketplace/IRareERC1155TradeExecutionModule.sol`
- `src/marketplace/IRareERC1155CheckoutExecutionModule.sol`

Integration scope:

- `MarketConfigV2` dependency bundle and the contracts it points to: marketplace settings, approved token registry, royalty engine, payments, staking settings, staking registry, space operator registry, ERC20 approval manager, and ERC1155 approval manager.
- Deployment and upgrade scripts that initialize or rotate marketplace dependencies and execution modules.
- Existing Foundry tests under `src/test/token/ERC1155` and `src/test/marketplace`, including settlement, checkout, gas, and upgrade-related coverage.

Out of scope unless requested separately:

- Full audits of legacy ERC721 marketplace contracts, staking contracts, royalty engine internals, and approval manager internals. Their behavior must still be modeled through mocks and integration assumptions because the ERC1155 marketplace trusts them.
- Platform operator error or misconfiguration, including incorrect deployment parameters, unsafe owner-authorized dependency rotation, incorrect registry administration, operational key management, or governance/timelock process failures. The audit should still verify that contract-level validation and access controls behave as specified.

## System Model

The ERC1155 collection is clone-based. `RareERC1155ContractFactory` deploys EIP-1167 clones of `RareERC1155`, then initializes each clone with caller ownership, collection metadata, a creator royalty receiver, and an optional default minter.

`RareERC1155Marketplace` is the UUPS proxy-facing state owner. It stores marketplace state in an ERC-7201 namespace and routes execution through delegatecall into two module contracts:

- `RareERC1155TradeExecutionModule` handles direct batch mints, batch listing buys, and offer acceptance.
- `RareERC1155CheckoutExecutionModule` handles best-effort multi-item carts that can fill valid items, skip invalid or failed items, and refund unused ETH.

`RareERC1155MarketplacePayments` centralizes payment collection, fee checks, split validation, primary payouts, secondary payouts, marketplace fee allocation, royalty payouts, and refunds.

The most sensitive design choices are:

- Delegatecall modules share marketplace proxy storage and execution context.
- Checkout intentionally catches per-item failures and continues.
- Offers escrow buyer funds up front and allocate marketplace fees across partial fills.
- ETH payouts and refunds route through `Payments`; ERC20 payouts transfer directly.
- Direct sale minting depends on collection-wide minter approval granted to the marketplace.
- Secondary transfers depend on an ERC1155 approval manager rather than direct marketplace operator approval.

## Assets and Security Objectives

Assets at risk:

- Buyer ETH and ERC20 funds.
- Seller ERC1155 balances.
- Escrowed offer funds and marketplace fee reserves.
- Creator primary-sale proceeds and royalty proceeds.
- Network beneficiary and staking reward fees.
- Collection lifetime mint supply and per-token max supply.
- Marketplace storage integrity across UUPS upgrades and module delegatecalls.
- Marketplace and collection owner authorities.
- Sale, offer, checkout, and token creation event integrity for off-chain indexers.

Core objectives:

- No buyer can receive tokens without paying the exact configured gross amount plus required fees.
- No seller can lose tokens without the expected sale proceeds being paid or escrowed according to payment rules.
- No token can be minted above its lifetime max supply, including after burns.
- Marketplace state transitions remain atomic for ordinary trade execution.
- Checkout skips must not leak state, tokens, or funds from failed items.
- Offer escrows must always conserve buyer principal plus remaining marketplace fee.
- Delegatecall modules must not be callable as standalone settlement contracts.
- Upgrades and module rotations must preserve storage layout and cannot accidentally disable critical guards.
- Approved currencies, split recipients, royalties, staking fees, and platform commissions cannot break accounting or liveness.

## Threat Model

Auditors should assume the following adversaries:

- Malicious buyer attempting underpayment, replayed checkout items, ERC20 allowance races, self-purchase bypasses, or reentrancy through token receiver hooks.
- Malicious seller attempting stale listings, revoked approvals, balance manipulation, self-dealing, malicious split recipients, or royalty DoS.
- Malicious collection contract that claims ERC1155 support but returns inconsistent balances, reverts selectively, mints incorrectly, or implements hostile receiver callbacks.
- Malicious ERC20 that charges transfer fees, returns malformed data, reenters through approval manager hooks, or mutates balances unexpectedly.
- Malicious payout recipient that reverts, consumes gas, or attempts reentrancy from fallback functions.
- External dependency contracts returning extreme fee values, zero reward accumulators, excessive royalty arrays, or failing static calls.
- MEV actors racing listing cancellation, offer cancellation, allowance revocation, ownership transfer, sale start, allowlist expiry, and price changes.

Trusted roles and assumptions:

- Marketplace owner can upgrade the UUPS implementation and rotate dependencies and execution modules.
- Correct platform operation of privileged owner actions is trusted and excluded from this audit except for contract-level guardrails explicitly implemented in code.
- Collection owner controls token creation, token URI updates, royalty receiver updates, minter approvals, and direct-sale configuration.
- Approved minters have collection-wide mint authority over all existing token ids.
- Approved token registry screens ERC20s, but marketplace code still rejects fee-on-transfer behavior at settlement time.
- `Payments` is expected to prevent ETH recipient DoS by escrowing failed ETH sends.
- Token allowlist roots are intentionally stored per `(collection, tokenId)`, while leaves are address-only: `keccak256(abi.encodePacked(account))`. Reusing the same address allowlist root across multiple tokens is an intentional collection-owner configuration choice, not a cross-token proof replay issue. Future audits should only flag this area if an unauthorized caller can set/reuse a root, if the documented off-chain leaf format diverges from on-chain verification, or if the product requirement changes to require roots cryptographically bound to `(collection, tokenId, account)`.
- Direct-sale setup intentionally allows `price == 0` for free mints, `startTime == 0` for immediately live sales, and `maxMints == 0` for no per-transaction quantity cap. These are collection-owner-controlled drop configuration choices, not missing validation, provided zero-price execution preserves zero gross amount, zero marketplace fee, zero payout, and exact payment checks.
- Creators are intentionally allowed to mint ERC1155 inventory to themselves and later sell that inventory through secondary listing or offer paths. This means a creator can choose a secondary-market sale route instead of the direct-sale mint route, even when that route avoids primary-market platform commission. This is an accepted product tradeoff in favor of creator custody and flexibility, not a security finding, as long as the selected settlement path still charges and distributes the fees required for that path.

## Audit Workstreams

### 1. Specification and Architecture Review

- Build a state-machine diagram for each user-facing flow: collection creation, token creation, minting, direct sale setup, direct sale cancellation, allowlist setup, limit setup, listing setup, listing cancellation, offer creation, offer cancellation, direct mint purchase, listing purchase, offer acceptance, and checkout.
- Confirm intended semantics for best-effort checkout: which failures should skip an item, which failures should revert the whole cart, and what observable event/result data must be emitted.
- Confirm business rules for primary fees, secondary fees, staking fee split, royalties, platform commission, split rounding, allowlist expiry, mint limits, transaction limits, max mints per transaction, and sale/listing expiration.
- Confirm deployment assumptions for UUPS proxy initialization, module deployment, module rotation, and clone factory configuration.

### 2. Access Control and Authority Review

- Verify every owner-only marketplace setter validates non-zero and contract-code requirements where appropriate.
- Verify `RareERC1155.renounceOwnership` cannot make creator resolution return zero.
- Verify collection disablement permanently blocks all intended owner-managed writes and minting paths.
- Verify direct sale setup and cancellation require current collection ownership.
- Verify collection ownership transfer after sale setup cannot allow stale direct sale configs to mint under a former owner.
- Verify approved minter behavior is intentionally collection-wide and cannot be confused with per-token sale authorization.
- Verify module contracts reject direct external calls and only execute through marketplace delegatecall.

### 3. Delegatecall, UUPS, and Storage Review

- Confirm marketplace, trade module, and checkout module all share the exact `RareERC1155MarketplaceStorage` layout and ERC-7201 storage slot.
- Confirm module immutables, inherited storage, and local state do not collide with proxy state. Execution modules must remain storage-less except for immutables; persistent marketplace fields belong only in the ERC-7201 `MarketplaceStorage` namespace.
- Confirm UUPS initialization cannot be repeated and implementation contracts are locked.
- Diff storage layout against the currently deployed or target-base implementation before upgrade. Run `script/marketplace/check-erc1155-storage-layout.sh`; `RareERC1155Marketplace` should show only OZ upgradeable inherited storage/gaps, while `RareERC1155TradeExecutionModule` and `RareERC1155CheckoutExecutionModule` should show empty storage arrays.
- Verify module rotation cannot point to EOAs, zero addresses, destructed contracts, or contracts with incompatible selectors.
- Add tests proving old offer, listing, limit, and direct-sale state remains readable after implementation/module upgrades.

### 4. Token Invariants

Required properties for `RareERC1155`:

- Token ids start at 1 and are monotonically increasing.
- `maxSupplyForToken(tokenId) == 0` only for non-existent token ids.
- `totalMintedForToken(tokenId)` is monotonic and never decreases on burn.
- `totalMintedForToken(tokenId) <= maxSupplyForToken(tokenId)` for every created token id.
- Minting zero amount, minting to zero address, minting unknown token ids, duplicate batch token ids, unsorted batch token ids, and oversized batches revert.
- `mintTo` and `mintBatchTo` enforce the same mint authority and supply constraints.
- Owner and approved minters can mint; all other accounts cannot.
- Collection-wide royalty receiver updates propagate to all existing token ids while preserving each token's royalty percentage.
- Default royalty percentage updates do not mutate existing token-specific royalty percentages; they only affect fallback royalty info and tokens created afterward.
- Token-specific royalty receiver updates preserve the token-specific royalty percentage until a later collection-wide receiver update.
- ERC165 support includes ERC1155, ERC2981, `IRareERC1155`, and `ITokenCreator`.
- `uri(tokenId)` returns token-specific URI when present and base URI fallback otherwise.
- Disabled collections reject token creation, minting, minter updates, royalty updates, and URI updates while preserving reads, transfers, and burns according to intended policy.

### 5. Marketplace Accounting Invariants

Required properties for direct sale mints:

- Buyer payment equals `sum(price * quantity + marketplaceFee)` for all filled items.
- Zero-price direct-sale mints are valid: gross amount, marketplace fee, payout, and required payment are all zero.
- Per-address mint limits and transaction limits increase only for successful mints.
- Checkout failures roll back limit counter increments for skipped items.
- `maxMints` applies per transaction and across duplicate checkout items for the same token id.
- Transaction limits count one successful mint transaction per `(buyer, collection, tokenId)`, so duplicate direct-sale checkout items for the same token in one checkout consume one transaction-limit unit while mint limits still consume total minted quantity.
- Direct sale seller remains the current collection owner at execution time.
- Allowlist proof verification uses the exact intended leaf domain and cannot be reused across incompatible contexts if domain separation is required.
- Mint balance deltas prove the buyer received exactly the requested quantity.

Required properties for secondary listing buys:

- Seller cannot buy from self.
- Sale price, currency, expiration, available quantity, approval, and seller balance are checked at execution time.
- Listing quantity decreases exactly by the filled amount and deletes at zero.
- Failed checkout listing items do not decrease listing quantity or collect payment.
- Transfer balance deltas prove seller lost and buyer received exactly the requested quantity.
- Creator-owned, pre-minted `RareERC1155` inventory is allowed to settle through the secondary listing path. Auditors should not classify primary-market commission avoidance from that creator choice as a protocol bug unless the product requirement changes.

Required properties for offers:

- Offer creation escrows gross amount plus marketplace fee and refunds any replaced offer.
- Offer cancellation deletes state before refunding.
- Offer acceptance cannot be performed by the buyer.
- Partial fills reduce quantity and marketplace fee remaining using cumulative allocation, not naive per-fill rounding.
- Final fill deletes all offer fields and pays exactly the remaining marketplace fee.
- Expired offers cannot be accepted but can be cancelled and refunded.
- ERC20 and ETH offer refund paths cannot leave stale offer state that can be double-refunded.

Required properties for checkout:

- `filledCount + skippedCount == items.length`.
- `ethSpent + ethRefunded == msg.value` for ETH-denominated filled items and skipped ETH items.
- ERC20 is collected per filled ERC20 item only after payment prechecks pass.
- Mixed ETH and ERC20 carts cannot cross-subsidize failed items.
- Per-item failure stages are stable: validation, payment collection, mint, transfer, payout.
- Reverts from external calls cannot spoof an incorrect failure stage or corrupt result decoding.
- Unknown future item kinds are skipped with an unsupported-kind failure, not executed.
- Events and returned `CheckoutExecution` results are consistent for every item.

Required properties for payouts:

- Split ratios must sum to 100 and have no zero recipients or zero ratios.
- Split rounding remainder goes to the last recipient and total payout equals sale amount.
- Primary sale platform commission cannot exceed 100%.
- Secondary royalties cannot exceed sale amount.
- Secondary royalty payouts follow the existing v2 marketplace policy: at most the first five royalty recipients returned by the royalty engine are paid.
- Secondary royalty recipients with nonzero royalty amounts cannot be the zero address, preventing ETH from being forwarded to `Payments` without a withdrawable payee.
- Staking fee cannot exceed marketplace fee.
- Zero-value recipients are skipped for ERC20 payout loops where applicable.
- Failed ETH recipient sends are escrowed through `Payments` instead of reverting the sale.
- ERC20 fee-on-transfer tokens are rejected during payment collection.

### 6. Reentrancy and External Call Review

High-priority external call sites:

- ERC1155 `safeTransferFrom`, `safeBatchTransferFrom`, `balanceOf`, `balanceOfBatch`, `isApprovedForAll`, and `mintBatchTo`.
- ERC20 `balanceOf`, `allowance`, approval manager `transferFrom`, and `safeTransfer`.
- Royalty engine `getRoyalty`.
- Payments `payout` and `refund`.
- Marketplace settings fee calculations and space operator/staking registry calls.
- Collection `owner()` staticcall used for direct sale ownership checks.

Required tests:

- Reenter marketplace write functions from ERC1155 receiver callbacks during mints and transfers.
- Reenter marketplace write functions from malicious ETH recipients through payout/refund paths.
- Reenter or mutate balances from malicious ERC20 `balanceOf`, `allowance`, `transfer`, and approval-manager-mediated `transferFrom`.
- Reenter from royalty receiver discovery or malicious royalty engine responses.
- Confirm `nonReentrant` on the marketplace facade still protects delegatecall module execution because delegatecalled code runs in marketplace context.
- Confirm best-effort checkout catches expected per-item failures but does not catch failures that should be whole-transaction invariant violations.

### 7. Denial-of-Service and Gas Review

- Measure worst-case gas for `MAX_BATCH_SIZE == 75` trade batches and `MAX_CHECKOUT_SIZE == 50` checkout carts.
- Stress maximum split recipients, maximum royalty recipients from royalty engine, mixed currencies, repeated duplicate direct-sale checkout items, and all-skipped checkout carts.
- Treat long Merkle allowlist proofs as caller-paid gas overhead unless evidence shows a third-party griefing path. Proof verification hashes once per supplied proof element, so an oversized proof can make the caller's own mint/checkout more expensive, but it does not force work onto other users or persistent state.
- Confirm no user can force persistent storage growth without paying expected costs or create unbounded loops over attacker-controlled historical state.
- Confirm payout recipient arrays from royalty engine cannot make settlement exceed block gas in common marketplace flows; ERC1155 settlement truncates royalty recipients to the first five before summing or paying royalties.
- Confirm Payments escrow path bounds recipient gas and preserves liveness for sales and refunds.

### 8. Static Analysis

Run and triage:

- `forge build`
- `forge test --no-match-path src/test/forks/**/*.sol`
- `npm run lint`
- Slither against the in-scope contracts, with explicit review of delegatecall, reentrancy, arbitrary-send, unchecked-transfer, missing-events, and weak-prng findings.
- A second static analyzer such as Aderyn or Semgrep Solidity rules to catch tool-specific gaps.
- Storage layout extraction before and after proposed upgrades, including `script/marketplace/check-erc1155-storage-layout.sh`.

Expected false positives:

- Intentional delegatecall from marketplace into trusted execution modules.
- Intentional low-level calls to `Payments`.
- Intentional unchecked loop increments after bounded batch-size validation.
- Address-only Merkle allowlist leaves without `(collection, tokenId)` domain separation; roots are keyed by `(collection, tokenId)`, and intentional root reuse across tokens is owner-controlled.
- Unbounded per-item Merkle proof arrays for mint/checkout allowlists; extra proof elements only add caller-paid calldata and hashing gas, making this self-DoS rather than a marketplace or third-party DoS vector.
- Permissive direct-sale parameters where `price == 0`, `startTime == 0`, or `maxMints == 0`; these intentionally mean free mint, immediately live sale, and unlimited per-transaction quantity respectively.

False positives must still be documented with the exact invariant or test that makes each pattern safe.

### 9. Fuzzing and Stateful Invariant Testing

Implement Foundry invariant suites with actors for buyer, seller, creator, marketplace owner, malicious ERC1155 receiver, malicious ERC20, malicious royalty engine, and rejecting payout recipient.

Suggested invariant handlers:

- Token handler: create tokens, approve minters, mint single, mint batch, burn, transfer, disable, update royalty, update URI.
- Marketplace handler: configure direct sales, configure allowlists, configure limits, set listings, cancel listings, make offers, cancel offers, mint direct sale, buy listing, accept offer, checkout mixed carts.
- Admin handler: pause/unpause, rotate dependencies to valid mocks, rotate execution modules to compatible mocks, upgrade proxy in a harness.

Global invariants:

- Marketplace ETH plus ERC20 balances equal active offer escrow plus transient checkout balances at transaction end, excluding funds intentionally handed to `Payments`.
- No account receives ERC1155 balance delta without an equal settled payment obligation.
- No seller loses ERC1155 balance delta without payout, escrow, or expected revert.
- Sum of active offer remaining principal and marketplace fee remaining equals escrow owed to buyers.
- Listing quantities never underflow and never become non-zero after delete.
- Checkout skipped items have no persistent side effects.
- Paused marketplace rejects all configured write/execution entrypoints that are intended to pause.
- Direct module calls always revert.

### 10. Fork and Deployment Validation

- Run deployment scripts against a local fork with the target mainnet/base addresses.
- Verify proxy initialization arguments, owner, UUPS implementation slot, module addresses, marketplace dependency addresses, and approval manager addresses.
- Simulate module rotation from old settlement architecture to trade/checkout modules if this audit supports an upgrade.
- Replay representative live-style flows on fork: creator collection setup, token creation, direct sale mint, listing buy, offer lifecycle, mixed checkout, payout recipient escrow.
- Confirm ABI generation and frontend-facing interfaces match deployed selectors and events.

## High-Risk Review Questions by Contract

`RareERC1155.sol`:

- Can any approved minter mint unintended token ids after creator approval?
- Can lifetime max supply be bypassed through burns, batch duplication, reentrancy, or malformed receiver hooks?
- Are royalty percentage units and ERC2981 basis points conversions consistently applied?
- Does disabling the contract intentionally leave transfers and burns available?

`RareERC1155ContractFactory.sol`:

- Can the factory owner point clones to an incompatible implementation?
- Are clones initialized atomically and impossible to front-run or reinitialize?
- Is the default minter configuration safe for marketplace deployment order?

`RareERC1155Marketplace.sol`:

- Does every public write path have the intended pause and reentrancy behavior?
- Do owner dependency and module setters enforce the contract-level guardrails specified in code, excluding platform operator error or intentionally unsafe authorized changes?
- Does delegatecall bubble errors correctly for non-checkout execution?
- Are cancellation functions intentionally callable while paused?

`RareERC1155MarketplaceStorage.sol`:

- Is the ERC-7201 slot correct and stable?
- Are batch-size limits sufficient to bound every loop using user-provided arrays?
- Is the documented address-only Merkle allowlist leaf format consistently used off-chain and on-chain, and are only authorized collection owners able to configure per-token roots?
- Are ERC1155 and owner checks robust against malformed contracts?

`RareERC1155ExecutionModuleBase.sol`:

- Are shared validation helpers identical between revert-all trade flows and best-effort checkout flows?
- Can `_decodeCheckoutItemExecutionFailed` return memory that is later corrupted or misinterpreted?
- Does marketplace fee allocation for partial offers handle all rounding and final-fill cases?

`RareERC1155TradeExecutionModule.sol`:

- Are state writes performed before external calls only where reentrancy protection and rollback semantics make that safe?
- Can listing or offer state be consumed before a transfer/payout failure in a way that creates stuck state?
- Are batch transfer balance checks sufficient for non-standard ERC1155 implementations?

`RareERC1155CheckoutExecutionModule.sol`:

- Can a failed checkout item leak payment collection, limit counters, listing decrements, or minted/transferred tokens?
- Are nested delegatecalls to the checkout module necessary and safe under the module rotation model?
- Can failure data spoofing produce misleading stages or suppress critical failures?
- Are ETH refunds correct for mixed-currency carts and all-skipped carts?

`RareERC1155MarketplacePayments.sol`:

- Does every payout path conserve value exactly after fees, royalties, staking, platform commission, and splits?
- Are ERC20 transfers compatible only with approved plain ERC20s, and is fee-on-transfer rejection sufficient?
- Can malicious royalty or staking dependencies force revert or gas DoS beyond intended policy?
- Are ETH refunds and payouts safe under the specified `Payments` interface and failure model?

## Evidence Matrix

| Property                                         | Manual review | Unit tests | Fuzz/invariant | Fork/deploy |
| ------------------------------------------------ | ------------- | ---------- | -------------- | ----------- |
| ERC1155 max supply cannot be exceeded            | Required      | Required   | Required       | Optional    |
| Burns do not reopen supply                       | Required      | Required   | Required       | Optional    |
| Clone initialization cannot be hijacked          | Required      | Required   | Optional       | Required    |
| Direct sale ownership is current at execution    | Required      | Required   | Required       | Required    |
| Checkout skipped items have no side effects      | Required      | Required   | Required       | Optional    |
| ETH accounting conserves `msg.value` in checkout | Required      | Required   | Required       | Optional    |
| ERC20 fee-on-transfer rejected                   | Required      | Required   | Required       | Optional    |
| Offer partial fee allocation is exact            | Required      | Required   | Required       | Optional    |
| Delegatecall modules cannot run standalone       | Required      | Required   | Required       | Required    |
| UUPS/module upgrade preserves storage            | Required      | Required   | Optional       | Required    |
| Payout recipient DoS does not block ETH sales    | Required      | Required   | Required       | Required    |
| Pause behavior matches policy                    | Required      | Required   | Required       | Optional    |

## Deliverables

Auditors should produce:

- Architecture and trust-boundary memo.
- Threat model and attack tree notes.
- Findings report with severity, exploit narrative, affected contracts, proof of concept, and remediation guidance.
- Test gap report with proposed unit, fuzz, invariant, fork, and gas tests.
- Static analysis triage log, including documented false positives.
- Storage layout and upgrade safety memo.
- Remediation verification report after fixes.

## Acceptance Criteria

Before sign-off:

- All critical and high findings are fixed or explicitly accepted with owner sign-off.
- All medium findings have remediation, mitigation, or documented risk acceptance.
- In-scope Foundry tests pass.
- New invariant tests cover token supply, checkout side effects, offer escrow accounting, and delegatecall-only modules.
- Static analysis findings are triaged.
- Deployment scripts have been simulated on fork with final addresses.
- Storage layout compatibility is documented for any marketplace upgrade.
- A final smoke test exercises collection creation, token creation, direct mint purchase, listing purchase, offer lifecycle, mixed checkout, failed payout escrow, pause/unpause, and module direct-call rejection.
