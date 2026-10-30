# Cart commerce

The Cart contract work is maintained on `keegan/cart-fixed-quote-currency-swap` in [PR #26, Add atomic commerce cart](https://github.com/superrare/core/pull/26), targeting `main` in `superrare/core`.

The branch combines free Listings and zero-total Orders with the listing digest index, ordered-line hashing improvements, ERC-721 mint-result returns, and backend resource admission. The `keegan/recovery-*` branches preserve earlier checkout snapshots. They are recovery references; continue Cart development on the PR branch. The [reconciliation record](cart-checkout-reconciliation-2026-10-27.md) explains their origin.

## Contract responsibilities

| Contract or source | Responsibility |
| --- | --- |
| [Cart](../src/cart/Cart.sol) | UUPS implementation behind the stable approval and EIP-712 proxy address. Validates Purchase Orders and seller authorizations, reserves inventory, executes settlement and NFT fulfillment, and emits reconciliation events. |
| [ICart](../src/cart/ICart.sol) | Canonical purchase arguments, fulfillment kinds, mint results, events, and errors. |
| [CartStorage](../src/cart/CartStorage.sol) | Namespaced configuration, seller authorization and inventory state, and order replay state. The [storage baseline](../src/cart/Cart.storage-layout.json) and upgrade canary guard compatibility. |
| [CartPayments](../src/cart/CartPayments.sol) | Delegatecalled payment executor. Collects the exact caller-funded quote, routes funds, pays signed obligations, captures protocol spread, and restores tracked balance and allowance baselines. Its address is immutable in the Cart implementation. |
| [CartRoutePolicy](../src/cart/CartRoutePolicy.sol) | Stateless command-family and array-shape checks for the opaque Universal Router program. Its address is immutable in both Cart and CartPayments. |
| [CartLens](../src/cart/CartLens.sol) | Separately deployed advisory Listing, order-envelope, and route preflight. Full execution simulation is still required. |
| [CartHashing](../src/cart/CartHashing.sol) and [CartHashes](../src/cart/CartHashes.sol) | Shared EIP-712 hashing library and optional stateless helper for clients. |
| [CartValidation](../src/cart/CartValidation.sol) | Internal fulfillment classification and collection-owner checks shared by Cart and CartLens. Each caller retains its check order and diagnostics. |

## Current contract behavior

- The platform signs the complete Purchase Order. Sellers sign reusable Merkle Listing Roots. The transaction caller supplies the exact fixed quote; fulfillment recipients are independent of the payer.
- Each Order Line names its payout currency, amount, and recipient. Seller-backed lines must meet the Listing's per-unit proceeds floor. Fees and other platform-authorized charges use peer lines.
- Fulfillment supports ERC-721 and ERC-1155 transfers and the supported `mintTo` interfaces, plus off-chain fulfillment. `NONE` requires no fulfillment job. `CURRENCY_SWAP` is a listing-less conversion through the order-wide route.
- Free Listings and zero-total Orders retain signature, inventory, replay, fulfillment, and balance protections. ERC-721 mint actions return token IDs through `MintResult[]` and emit fulfillment events.
- Favorable routing variance goes to the nonzero `spreadRecipient` in the signed Purchase Order. There is no global recipient setting. The signed quote is collected exactly, and tracked preexisting balances must survive settlement.
- Cart, Lens, and route policy impose no numerical resource caps. The signing service owns gas, byte, and workload admission. Structural, authorization, custody, and route-family checks remain on-chain.

The [contract design](cart-contract-design.md) describes the full behavior. [Commerce language](../CONTEXT.md) defines the terms. [ADR 0001](adr/0001-cart-route-policy.md) records the route boundary, and [ADR 0002](adr/0002-uups-cart-for-stable-approvals.md) records the stable proxy decision. [ADR 0003](adr/0003-signed-cart-spread-recipient.md) records the signed spread destination. Use the [Cart runbook](cart-runbook.md) for signer rotation, pausing, ownership, upgrades, and seller invalidation.

## Integration guidance

Use [ICart](../src/cart/ICart.sol) for ABI tuple field order and [CartHashing](../src/cart/CartHashing.sol) for EIP-712 type definitions. Build bindings from the current source rather than reconstructing types from prose. The [transaction-builder handoff](cart-transaction-builder-handoff.md) covers fee consolidation, final payload signing, admission, and split checkout behavior. The [resource policy](cart-resource-policy.md) distinguishes backend limits from contract checks.

The transaction builder, SDK, CLI, and settlement consumers are maintained outside this repository. Their integration work must use the confirmed chain addresses and the current ABI. A passing contract suite does not establish their rollout status.

## Deployment records

[NetworkConfig](../script/NetworkConfig.s.sol) records the Sepolia addresses. The [October 27 deployment record](cart-sepolia-free-listings-2026-10-27.md) and [receipt ledger](data/cart-sepolia-free-listings-2026-10-27.json) describe the confirmed free-listing repair, preserving the proxy, route policy, and CartHashes while replacing CartPayments, Cart, and CartLens. The [October 26 record](cart-sepolia-upgrade-2026-10-26.md) is deployment history; its implementation, payment executor, and Lens were superseded.

The signed spread-recipient change has not been deployed. These records describe the older order ABI and its global protocol recipient. A future rollout must replace CartPayments, Cart, CartLens, and CartHashes together and regenerate client bindings. Old checkout payloads require new signatures.

These records establish the recorded Sepolia deployment. Other chains require separate deployment evidence. Use the scripts in [script/cart](../script/cart) for the intended upgrade scope: the implementation-only helper is disabled for the signed-checkout migration. The combined helpers replace the executor and current integration helpers together. Policy changes also require a matching new policy. The checkout guard protects deployment sources against detached, dirty, or stale checkouts.

## Verification

Run the Cart unit, fuzz, invariant, and storage-upgrade tests from the repository root:

```sh
FOUNDRY_PROFILE=cart forge test --offline
```

The profile selects [src/test/cart](../src/test/cart). Shared setup and builders live in abstract fixtures, and token/router mocks live in `CartMocks.sol`; executable suites inherit fixtures without inheriting other suites' tests. Live-dependency fork tests in [src/test/forks/ethereum/cart](../src/test/forks/ethereum/cart) require a separate RPC-backed run. Historical gas reports use their recorded environments and do not replace current RPC estimates.

The [formal-verification project](../verification/cart/README.md) documents its modeled properties and limitations. Its saved results are separate evidence from the native test suite and must be checked against the source used for any new proof claim.

The [cleanup verification](cart-cleanup-verification.md) records preserved test scenarios, ABI and storage checks, runtime sizes, and checkout-gas comparisons for the internal refactor.

The [signed spread-recipient verification](cart-signed-spread-verification.md) records tests, gas, runtime sizes, ABI changes, and reserved-slot checks for the checkout interface change.
