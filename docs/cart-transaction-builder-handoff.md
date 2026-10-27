# Consolidate fee lines in the Cart transaction builder

Implement fee consolidation for newly constructed Purchase Orders. Use the existing Cart ABI and EIP-712 types. This change affects order construction, receipt data, and settlement consumers. It does not require a Cart implementation upgrade or new seller signatures.

The seller's Listing already authorizes proceeds after the seller-funded fee. Preserve those Listing values and their existing authorizations. The objective is to remove repeated fee lines while preserving the customer quote, seller proceeds, and every recipient's entitlement.

## Build and sign the order

1. Calculate each item's pricing and fees using the existing rules. Use integer token base units. Apply each fee's rounding rule before consolidation. Rates, fixed amounts, and buyer or seller attribution can differ between items.
2. Preserve the detailed fee allocations in the order record. Each allocation identifies the merchandise item, fee SKU or type, rate or fixed amount, rounded amount, settlement currency, recipient, and who bears the fee. Preserve the information needed for refunds and reconciliation.
3. Build merchandise Order Lines with the existing seller-net amounts and fulfillment terms. Keep their Listings, seller signatures, and Merkle proofs intact.
4. Group eligible fee allocations by their compatibility key. Use the grouping rules below. Do not consolidate merchandise, listing-backed charges, or Currency Swap lines in this change.
5. Emit one Order Line per nonzero fee group with the fields below. Retain a mapping from every source allocation to its final fee line.
6. Finalize the line ordering deterministically. Create the original-line or merchandise-item to final-line-index mapping. Remap each Fulfillment Action's `lineIndex` against this final array. Preserve action order, quantities, and recipients.
7. Verify that total obligations for every exact settlement currency and recipient match the unconsolidated order. Preserve the existing `paymentCurrency`, `paymentAmount`, and routing economics. Do not sum amounts across different currencies to derive `paymentAmount`.
8. Build the final route and actions, then compute `orderLinesHash`, `payoutRouteHash`, and `fulfillmentActionsHash` from those final arrays. Sign the final Purchase Order with the platform signer. Never edit the arrays after signing.
9. Persist the exact signed order, final line indexes, and fee-allocation mapping together before submitting it. Use the existing quote identity rules. If replacing an already signed quote, retain its immutable records and avoid attaching its signature or identifier to a different allocation record.
10. Validate and estimate gas for the complete signed payload with the actual payer, value, contracts, and route. Apply backend admission to the complete payload before presenting it for wallet approval. Cart, CartLens, and CartRoutePolicy no longer impose numerical resource caps. See the admission procedure below.

The builder implementation is outside this contracts repository. Apply these steps where the application creates the `executePurchase` arguments and its receipt records.

## Decide which fees can share a line

Group charges only when their recipient, exact settlement currency, fee SKU or purpose, and required accounting treatment are compatible. Use an explicit compatibility key in the builder rather than guessing from equal wallet addresses.

Do not include the percentage or individual amount in that key. Different rates and amounts can share a group after each fee is calculated and rounded. Buyer-funded and seller-funded fees can also share a group if aggregate on-chain reporting is acceptable and the allocation record preserves their attribution. Include attribution in the key when downstream consumers require separate on-chain totals for those categories.

Keep distinct fee SKUs and purposes separate for the initial implementation. Shipping, tax, royalties, and platform compensation must not merge merely because their recipient matches. Different refund or accounting rules can also require separate groups. Use existing stable fee SKUs; do not derive a new SKU from each order's contents.

ETH and WETH are distinct settlement currencies. Normalize address representations before comparing keys, while keeping the native zero address distinct from the WETH contract. Preserve the exact chain and token identity.

An aggregate fee line has these fields:

| Field | Value |
| --- | --- |
| `sku` | Existing nonzero fee SKU shared by the group |
| `listingDigest` | Zero |
| `fulfillmentKind` | `NONE` |
| `quantity` | `1`, representing one aggregate charge |
| `settlementCurrency` | Exact group currency |
| `amount` | Sum of the already calculated, rounded fee amounts |
| `paymentRecipient` | Group recipient |

Each amount must fit `uint256`. Omit zero-total groups because Cart rejects zero-amount lines. Do not encode negative discounts or refunds as unsigned fee amounts. Preserve the existing pricing treatment for those adjustments.

## Keep customer receipts and settlement consumers consistent

The on-chain event contains each aggregate fee line, not its individual allocations. Store and show the item-level breakdown from the immutable order record. The current ABI does not commit to that breakdown separately from the aggregate amount.

Update consumers that assume one fee line per item or infer item count from total line count. Reconcile a fee group's settlement against its aggregate amount, then resolve its allocations through the saved mapping. Continue using final on-chain line indexes for settlement-event identities. Do not count `NONE` lines as merchandise or dispatch fulfillment for them.

If individual fees must remain independently provable from on-chain events, retain the required separate lines. Adding a cryptographic commitment to the allocation breakdown would be a separate interface design.

## Example

Assume two merchandise items settle in the same token. Item A costs 100 and carries a seller-funded fee of 10. Its seller receives 90. Item B costs 200 and carries a buyer-funded fee of 10. Its seller receives 200 and the buyer pays 210 for that item.

The customer pays 310 in total. If the two platform fees can share a reporting group, the final order has merchandise lines paying 90 and 200 plus one fee line paying 20. If buyer and seller fee categories must remain separate on-chain, use two fee lines paying 10 each. Both representations preserve the pricing and the seller authorizations.

The observed nine-item Sepolia order has nine `NONE` lines with one shared fee SKU and a further `NONE` line with a different SKU. Grouping the repeated SKU while retaining the other SKU reduces 19 lines to 11, subject to compatible accounting treatment. See the [decoded charge examples](data/cart-gas-2026-10-24/charge-line-examples.json).

## Verify the builder change

Cover these cases in the builder's tests:

- Different percentage fees, flat fees, and buyer or seller attribution, including amounts that require rounding.
- Compatible repeated fees merge even when their rates or amounts differ.
- Different fee SKUs, recipients, currencies, or incompatible accounting treatments remain separate. ETH and WETH remain separate.
- Merchandise fields, seller authorization, fixed customer quote, and per-currency recipient totals remain identical before and after consolidation.
- Interleaved fee and merchandise lines produce correct final Fulfillment Action indexes and quantities.
- Zero-fee allocations remain available in the breakdown but produce no zero-amount on-chain line.
- Recomputed hashes and the platform signature validate the final payload. A signature over the unconsolidated payload does not validate the changed payload.
- Aggregate settlement events reconcile to the saved item-level allocations, including partial refunds handled by the application.
- Final payloads at the supported capacity pass the actual preflight and execution checks. Quote construction reports a capacity issue before requesting a wallet transaction.

The controlled contract-side compaction cases are in [CartQuoteCapacity.t.sol](../src/test/cart/CartQuoteCapacity.t.sol). They verify payout totals and demonstrate fewer lines, but do not replace tests in the transaction builder.

## Admit checkouts in the backend

Enforce admission in the service that constructs and authorizes orders. A frontend cart-size check is advisory. Validate complete payloads in the signing service; do not blindly sign client-supplied hashes. Keep the signing key behind that service.

1. Apply configurable request limits before expensive decoding, proof validation, signing, or simulation. Bound request bytes, array counts, proof bytes, signature bytes, route input bytes, and expanded mint quantities. These protect backend work and RPC requests. They are operational settings, not contract capacities.
2. Validate the final lines, Listings, roots, proofs, actions, and route. Check seller signatures, net amounts, availability, deadlines, recipients, exact per-line action coverage, route families, and payment totals. Count each ERC-721 mint unit as a separate call. Multiple action recipients can increase calls without increasing line count.
3. Use 64 total Order Lines as an initial configurable builder policy if a rollout ceiling is needed. Fee groups count toward it. Do not preserve the former 20-operation or 32-command limits as protocol assumptions. Calibrate backend work limits against telemetry and supported token/route workloads. Line count cannot replace gas or byte admission.
4. Compute the final hashes and produce the platform signature internally. Estimate the complete signed `executePurchase` call against the intended chain, deployed Cart, actual payer, value, and current state. Include seller witnesses and the real route. Use ordinary caller balances and allowances; report missing approvals separately. CartLens validates only parts of the envelope and Listings; it cannot replace full execution simulation.
5. Calculate `submittedGasLimit = (estimateGas * 125 + 99) / 100` with integer division. Start with a configurable maximum submitted gas limit of 12,000,000. Admit only when the buffered limit fits this budget and the current chain and provider constraints. This admits estimates up to 9,600,000 gas. The margin is application policy, not a guarantee against state changes.
6. Check ABI calldata bytes and the serialized transaction envelope against the actual wallet, RPC, and relayer limits. Include envelope fields, access lists, and transaction signature overhead. Reserve a conservative envelope allowance before wallet signing, then verify the final serialized transaction when the sender controls it. Do not treat a node-specific byte threshold as a universal Ethereum limit.
7. Persist and release the exact admitted payload with its quote, gas estimate, submitted gas limit, byte counts, chain, Cart address, and deployment version. Keep gas metadata outside the signed Purchase Order. Any change to lines, route, actions, payer, value, or witnesses requires validation and simulation again. Changes to signed fields also require a new platform signature.
8. Refresh simulation before submission when the estimate is stale or relevant quote, inventory, approval, or route state has changed. A successful estimate does not reserve inventory or guarantee the next block's state. Use short quote deadlines and identify stale quotes or unavailable items before prompting the wallet where possible.

The exact platform signature must exist for realistic simulation. Perform cheap policy checks before signing and keep the signature internal until full admission succeeds. With a separately operated signing service, gate release on the trusted admission result and bind it to the complete payload and payer. Seller witnesses require their own validation even though they are not directly committed by the platform signature.

## Handle purchases that exceed the budget

Keep items in the customer's cart. Explain that checkout needs more than one transaction and propose the largest valid group that fits the measured budget. Rebuild and simulate every proposed group, because fees, routes, rounding, and gas are not additive. Recalculate each group's customer quote and fee allocations under the existing pricing rules. Issue separate order IDs and signatures. Separate purchases lose whole-cart atomicity; make that clear before approval and track partial completion.

Record estimated and receipt gas, estimate error, bytes, item and line counts, action counts, expanded mint calls, proof sizes, route commands, token contracts, and rejection reasons. Use those measurements to adjust admission settings. Do not infer a universal item limit from one collection's benchmark.

## Verify admission and rollout

Add builder tests for valid payloads above the old 20-operation and 32-command caps, purchases above 64 lines when policy permits, and one-line purchases with large mint quantities. Test the gas-budget boundary, byte-budget boundary, malformed witnesses, invalid signatures, mismatched action quantities, unsupported routes, stale quotes, and request rejection before expensive processing. Verify that a failed admission never releases a usable platform signature. Test split checkout pricing and partial completion.

Deploy the uncapped CartRoutePolicy and a new CartPayments executor constructed with that policy. Construct the new Cart implementation with both of those addresses. Cart and CartPayments each embed their policy address in bytecode. Reusing the old executor can preserve the 32-command cap during settlement even when Lens previews pass. Upgrade the Cart proxy and replace CartLens through the normal deployment process. Update generated ABIs and consumers of the removed `MAX_ROUTE_COMMANDS()` getter and resource-limit errors. Verify deployed bytecode and addresses before enabling larger backend orders. An older Cart, Lens, or route policy can still reject larger orders. The implementation-only upgrade script preserves dependencies and is insufficient for this policy change. This repository change does not deploy them.

Retain the existing seller authorization, route allowlist, payment, and custody checks. Removing numerical resource caps changes no purchase arguments, signed EIP-712 fields, or event schemas. See [Cart resource policy](cart-resource-policy.md) for the remaining contract checks and the token benchmark reports for measured examples.
