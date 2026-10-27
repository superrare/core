# Cart checkout capacity and limits

> Source update, October 26, 2026: Cart, CartLens, and CartRoutePolicy now have no numerical resource caps. Cap-specific results below describe the earlier measured source. The current real-token benchmark runner tests every listed size without changing contract constants; `--expanded` is retained as a compatibility flag. See [Cart resource policy](cart-resource-policy.md) and the [backend handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend).

Policy update, October 26, 2026: Cart and CartLens no longer impose a proof-depth cap. The observations below describe the earlier implementation. See [current resource policy](cart-resource-policy.md).

Research date: October 24, 2026. This investigation uses the current working tree and the [saved Sepolia purchase records](data/cart-gas-2026-10-24/purchases.json). It proposes a design and does not change deployed limits. The earlier [gas capacity report](cart-gas-capacity-research.md) records deployment checks, transaction receipts, and the original local experiments.

## One checkout policy can hide several contract limits

The product can expose one checkout decision: whether the complete cart fits in one transaction. An order-line count alone cannot answer that question. One ERC-721 mint line can request many mint calls, a listing can carry a deep Merkle proof, and one route input can contain a large swap program. External NFT contracts, payout recipients, signature-checking wallets, and routers also determine execution cost. These dimensions vary independently in [Cart](../src/cart/Cart.sol), [CartHashing](../src/cart/CartHashing.sol), and [CartPayments](../src/cart/CartPayments.sol).

The recommendation is to keep cart admission separate from transaction admission. Let customers keep adding items. Build the most compact valid signed order, simulate the complete transaction, and check its encoded size. Prepare multiple checkout transactions when one cannot accommodate the cart, with the transaction count and loss of whole-cart atomicity visible before the customer approves. Contract limits remain implementation details of that checkout module.

The current numerical caps are resource guardrails, rather than proofs that an order fits the chain. Their exact values can change after measurement. Authorization, exact fulfillment quantities, listing inventory, allowed route commands, and protection of existing balances remain necessary regardless of the resource policy. Removing a count check does not remove those correctness checks.

## What each current limit protects

| Current check | Work it bounds | Relationship to one top-level count | Recommendation |
| --- | --- | --- | --- |
| 32 order lines | Hashing, validation, listing lookup, payment aggregation, and settlement events | Includes fee lines and currency-swap lines, so it does not count merchandise items | Raise only with combined-workload measurements. Share one authoritative value with preflight. |
| 20 fulfillment operations | External NFT calls, including every ERC-721 mint unit | A single line and a single action can exceed this count through mint quantity | Retain an independent operation bound until measured replacement policy covers quantity-expanded work. The value 20 is not a chain requirement. |
| 20 action-array entries | Action hashing and validation | Every valid action costs at least one operation, so the operation bound already implies this maximum | Derive this early rejection from the operation policy. It is not an additional product limit. |
| 64 Merkle siblings per listing | Proof verification and witness bytes | Proof depth depends on the seller's signed listing root, not on this purchase's line count | Keep as a generous malformed-input guard. A balanced binary tree at depth 64 can commit up to 2^64 leaves, far beyond this sample's needs. |
| 32 route commands and 32 inputs | Top-level router program length and input hashing | One command can contain multiple swaps or other nested data. Command count does not bound bytes or gas | Keep the route allowlist. Retain or revise the count after route measurements. Derive the input count from command/input equality. |
| Listings no greater than lines; roots no greater than listings | Authorization arrays and validation loops | These are relationships between arrays, not independent business limits | Keep them as shape checks and derive their capacity from the line bound. |
| Serialized transaction size | Calldata plus transaction envelope | Many small lines and a few large proofs or route inputs can have the same byte size | Check actual serialized size against the supported node and provider policy at quote time. |
| Buffered full-transaction gas estimate | Actual work against the active contracts and current state | Captures costs that no item or byte count predicts | Use as the checkout admission decision, with a chosen reserve below the active network's transaction ceiling. |

Sources: the constants and early checks in [Cart](../src/cart/Cart.sol), quantity-expanded accounting in `Cart._validateActions`, the 20-line preflight check in [CartLens](../src/cart/CartLens.sol), and command/input equality plus the command allowlist in [CartRoutePolicy](../src/cart/CartRoutePolicy.sol). The original gas report links the chain gas and transaction-pool byte policies. Those policies must be checked for the target chain and provider before implementation.

`CartLens` currently accepts only 20 lines while Cart accepts 32. That discrepancy can reject a supported purchase before gas becomes relevant. Route count constants also appear in Cart, CartLens, and CartRoutePolicy. A shared source for supported bounds would avoid another mismatch. [CartLens](../src/cart/CartLens.sol) is advisory and does not replace execution or full-payload simulation.

There is also an ordering issue in the early route guard. `executePurchase` copies the route to memory and computes `hashPayoutRoute` before `_executePurchaseCore` checks the route lengths. The comment that the length checks run before hashing is therefore inaccurate for the route. Moving shape checks before copying and hashing would improve early rejection of malformed inputs. The existing count checks also leave each individual route input's byte length unbounded. See [Cart.executePurchase](../src/cart/Cart.sol) and [CartHashing.hashPayoutRoute](../src/cart/CartHashing.sol).

## What a single contract limit could mean

A total byte cap can replace several independent array-count caps as a broad input-size guard. It cannot replace the fulfillment-operation bound because a fixed-size quantity field can request an enormous number of ERC-721 mint calls. It also does not bound gas spent inside an external contract. The native transaction gas limit prevents execution from exceeding the gas supplied, but reaching that limit causes a failed purchase and consumes gas.

A single shared number for lines, actions, proof nodes, and route commands would still impose separate checks. The number would express a convenience rather than a measured relationship between their costs. A weighted work budget is possible, but its weights would be a new policy to calibrate and would still fail to predict arbitrary external-call cost.

There is no demonstrated security need for every existing numerical cap to retain its present value. A different reviewed contract design could use fewer resource checks and rely more heavily on the platform signer and full-transaction simulation. That choice gives up deterministic bounds on malformed work before signature verification, and it needs deliberate treatment of relayers, RPC simulation resources, revert behavior, and quantity-expanded loops. The present evidence supports simplifying the caller's checkout interface before removing all internal guardrails.

## The current line count understates customer cart capacity

The saved history contains 182 distinct successful purchase hashes. Fifty-four use the latest implementation recorded in that snapshot. Their line classifications are below. A merchandise line here means a line whose kind is an NFT transfer, NFT mint, or `OFF_CHAIN`. The sample contains no `OFF_CHAIN` lines. `NONE` means no fulfillment workflow. It can represent fees, royalties, shipping, or services. The saved record does not identify each charge's commercial meaning. See [ICart.FulfillmentKind](../src/cart/ICart.sol) and the [design's line classifications](cart-contract-design.md).

| Saved sample | Merchandise lines | `NONE` lines | Currency-swap lines | Total lines |
| --- | ---: | ---: | ---: | ---: |
| All 182 purchases | 261 | 436 | 22 | 719 |
| Latest implementation, 54 purchases | 59 | 109 | 7 | 175 |

Forty-nine of the latest 54 purchases contain merchandise. In 48 of those 49, the number of `NONE` lines equals the merchandise line count plus one. Forty-four purchases contain one merchandise line and two `NONE` lines. The largest purchase contains nine NFT lines and ten `NONE` lines, for 19 total. Its gas use was 1,855,705 and it performed nine ERC-1155 transfers. [Saved purchase records](data/cart-gas-2026-10-24/purchases.json), [largest purchase](https://sepolia.etherscan.io/tx/0x0153e37813a0a727d7dfc744a1a3b3310f2ac523153aa61f227d4e06b7b20e95).

With one charge line per merchandise item plus one order charge, the line count is `2 * merchandiseItems + 1`. The capacity consequences are concrete:

| Encoding and bound | Maximum merchandise lines before that bound |
| --- | ---: |
| Current 20-line preflight, observed charge pattern | 9 |
| Current 32-line execution, observed charge pattern | 15 |
| 32-line execution, compatible per-item charges consolidated while retaining a separate order charge | 30 |
| Current 20-operation bound, one NFT operation per merchandise line | 20 |

The 30-item figure describes available line slots, not a promised executable cart size. Twenty-one individual NFT transfers would still fail the current operation check. Multiple fee recipients, currencies, SKUs, or accounting purposes require multiple consolidated lines. A single ERC-1155 line can transfer many units in one call, while an ERC-721 mint quantity consumes one operation per unit. Items, line records, units, actions, and operations must have distinct names in application metrics.

These transactions cover a small set of workload shapes. After grouping by ordered kinds, quantities, listing/root counts, proof counts/depth, action and operation counts, route-command count, recipient count, and settlement-currency count, the 54 latest purchases reduce to 14 shapes. All 182 reduce to 19. Every hash is distinct, so these are repeated structural workloads rather than duplicate transactions. This grouping does not compare actual NFT addresses, recipients, prices, routing paths, or prior storage state, which the saved summary does not retain. Frequency in this Sepolia sample cannot establish a mainnet customer-demand distribution.

The latest sample has 27 ERC-1155-transfer purchases, 16 ERC-721-transfer purchases, nine routed purchases, one ERC-1155 mint, and one ERC-721 mint. Routed purchases can also contain NFT lines. No observed purchase exceeds nine operations. The data supports removing avoidable line overhead. It does not establish capacity for 20 expensive real mints. [Purchase ledger](data/cart-gas-2026-10-24/purchases.csv), [trace summary](data/cart-gas-2026-10-24/trace-summary.json).

## Optimizations that can make more room

### Consolidate eligible charge lines before signing

Combining compatible `NONE` charges can increase merchandise capacity without changing Cart's ABI. Group only charges that can share the same SKU, recipient, exact settlement currency, and accounting purpose. Keep a separate order charge when its SKU or purpose differs. ETH and WETH remain distinct payout forms. A consolidated platform-only line can retain the common fee SKU, use zero listing digest, `NONE`, quantity one, and the sum of compatible charges. The platform must sign the resulting order. Existing signed payloads cannot be rewritten.

This proposal changes reconciliation detail. The [current design](cart-contract-design.md) intentionally represents royalties, shipping, handling, seller revenue, and platform compensation as explicit peer lines. [Cart._emitLineEvents](../src/cart/Cart.sol) reports those individual lines. Consolidation is appropriate only if the product can preserve the per-item allocation in its customer receipt and accounting records, and consumers accept an aggregate on-chain event. Charges with different tax, refund, royalty, or fulfillment semantics must not be merged merely because their recipients match.

The [decoded charge examples](data/cart-gas-2026-10-24/charge-line-examples.json) confirm a specific opportunity in the real nine-item purchase. Nine `NONE` lines share the same SKU, native currency, recipient, and amount of 150,000,000,000 wei each. The remaining `NONE` line has a different SKU and amount of 270,000,000,000 wei. Keeping that second SKU separate and grouping the nine compatible charges would reduce 19 lines to 11. The evidence proves matching fields, rather than matching commercial purpose or refund policy. Accounting compatibility still needs confirmation before changing quote construction.

Keep seller-authorized merchandise lines intact. Their SKU, settlement currency, recipient, quantity, and minimum price are tied to the signed Listing. After removing or moving other lines, rebuild every fulfillment action's line index and the signed line/action hashes. Preserve total obligations for every exact currency and recipient. [Cart._validateLineTerms](../src/cart/Cart.sol), [Cart._validateOrderHashes](../src/cart/Cart.sol), [CartHashing](../src/cart/CartHashing.sol).

This saves calldata, line hashing, validation loops, and settlement events. It may save no external payout calls: `CartPayments._payLines` already groups equal token/recipient/native-form obligations into one payout. The benefit must be measured against that existing grouping, rather than assuming each removed line removes a transfer. Each removed static OrderLine removes 224 bytes from the ABI array. [ICart.OrderLine](../src/cart/ICart.sol), [CartPayments._payLines](../src/cart/CartPayments.sol).

### Measured charge compaction

The [CartQuoteCapacity fixture](../src/test/cart/CartQuoteCapacity.t.sol) compares the same merchandise count and payouts before and after grouping compatible per-item charges. It retains a second charge with its own SKU. All six experiments passed. These cases use `OFF_CHAIN` listings, a common seller and payout recipient, native payment, and no NFT fulfillment. The numbers measure Cart bookkeeping and payment work rather than the real NFT calls in the historical purchase. [Saved measurements](data/cart-gas-2026-10-24/quote-compaction-benchmarks.json).

| Merchandise lines | Charge encoding | Seller authorization | Total lines | Calldata bytes | Approximate gas |
| --- | --- | --- | ---: | ---: | ---: |
| 9 | Per-item plus separate charge | Shared root | 19 | 10,468 | 822,888 |
| 9 | Grouped compatible charges plus separate charge | Shared root | 11 | 8,676 | 705,228 |
| 15 | Per-item plus separate charge | Shared root | 31 | 16,420 | 1,265,737 |
| 15 | Grouped compatible charges plus separate charge | Shared root | 17 | 13,284 | 1,059,200 |
| 30 | Grouped compatible charges plus separate charge | Shared root | 32 | 25,764 | 2,033,867 |
| 9 | Grouped compatible charges plus separate charge | Separate singleton roots | 11 | 9,572 | 768,806 |

Grouping saves 117,660 approximate gas at nine merchandise lines, or 14.3%. At 15 it saves 206,537, or 16.3%. It also frees eight and 14 line slots respectively. Thirty off-chain merchandise lines plus two charge lines execute in this local fixture without raising the current 32-line cap. That case does not exercise the NFT operation cap.

Approximate gas is the larger of gross external-call gas plus ordinary intrinsic gas and the calldata floor. The fixture cools Cart and WETH, but reads recipient balances before execution and therefore warms those accounts. It does not model every account's top-level transaction warmth, refunds, production recipients, or swap routes. The controlled comparisons support charge compaction; their absolute totals are not chain receipts.

Reproduce the six cases with the repository's Cart profile:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-path src/test/cart/CartQuoteCapacity.t.sol --match-test '^testQuote' -vvvv
```

### Share seller roots and deduplicate witnesses

Cart already verifies a root signature once per root index and reuses that result for the root's other listings. The quote builder should supply one listing entry per digest and reuse the root index for listings authorized by the same seller root. Separate singleton roots repeat signature data and checks. Deep proofs also add 32 bytes per sibling before execution cost. A new multiproof format could share branches, but requires an authorization-interface change and a separate review. [Cart._resolveRootListings](../src/cart/Cart.sol), [ICart.ListingPurchaseAuthorization](../src/cart/ICart.sol).

In the nine-item compact-charge fixture, a shared root uses 63,578 less approximate gas than separate singleton roots. The real nine-item Sepolia purchase already uses one shared root. The comparison validates that existing optimization, rather than a new saving available in that transaction. [Saved compaction measurements](data/cart-gas-2026-10-24/quote-compaction-benchmarks.json), [historical records](data/cart-gas-2026-10-24/purchases.json).

### Avoid repeated scans as capacity grows

Cart checks each new listing against earlier digests and searches listing digests for every line. CartPayments scans previously recorded tokens and payouts, and computes required amounts by scanning lines for each token. These costs grow with combinations of lines, listings, tokens, and recipients. A larger cap should include measurements where these are all distinct. A sorted or indexed representation may reduce work, but must preserve duplicate-listing rejection, the signed array order, exact per-token obligations, native/WETH treatment, and the line index attached to failures. [Cart._resolveRootListings](../src/cart/Cart.sol), [CartPayments._validateRoute](../src/cart/CartPayments.sol), [CartPayments._verifySolvency](../src/cart/CartPayments.sol), [CartPayments._payLines](../src/cart/CartPayments.sol).

Do not remove exact-receipt or preexisting-balance checks to increase capacity. The current payment executor checks recipient balance changes for ERC-20 payouts and verifies custody baselines before and after settlement. Those are settlement guarantees, not count-policy overhead. [CartPayments._transferExact](../src/cart/CartPayments.sol), [CartPayments._verifyFinalBaselines](../src/cart/CartPayments.sol).

### Measured payout-grouping candidate

An isolated candidate replaces the nested payout-group search with a temporary memory hash table. It preserves first-seen payout order, grouping by token/recipient/native form, the first line index for errors, the contract's ABI and state writes, and all later payout and custody checks. Sixteen complete-purchase scenarios pass against both baseline and candidate. Another 256 differential fuzz cases compare grouping outputs over zero through 128 lines, repeated recipients, and mixed native/token currencies. The [saved optimization results](data/cart-gas-2026-10-24/optimization-results.json) and [reproducible experiment bundle](data/cart-gas-2026-10-24/cart-optimization-experiment.tar.gz) retain the code, methods, and logs. No production implementation or limit changes form part of this experiment.

| Complete local workload | Lines | Calldata bytes | Baseline approximate gas | Candidate approximate gas | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Separate listing roots and payout recipients | 1 | 1,956 | 192,116 | 193,438 | 0.69% more |
| Separate listing roots and payout recipients | 20 | 18,980 | 1,733,465 | 1,609,139 | 7.17% less |
| Separate listing roots and payout recipients | 32 | 29,732 | 2,923,086 | 2,581,925 | 11.67% less |
| Separate listing roots and payout recipients | 64 | 58,404 | 6,914,210 | 5,488,488 | 20.62% less |
| Listing-less payments to distinct recipients | 32 | 8,228 | 1,150,991 | 809,830 | 29.64% less |
| Separate listing roots, proof depth 64, distinct recipients | 32 | 95,268 | 4,577,886 | 4,236,725 | 7.45% less |

These comparisons use identical payloads for baseline and candidate and account for the calldata floor. Both variants raise the line bound to 128 only inside the temporary experiment, so the 64-line case measures a proposed capacity rather than current execution support. The listing scenarios use off-chain fulfillment. They do not establish capacity for 64 real NFTs, production receivers, or swap routes. Account warmth, refunds, and the outer test CALL also differ from transaction receipts. Small differences from the original capacity report's baseline follow from the temporary fixture/compiler context; compare only paired variants in this experiment.

The largest observed purchase has two payout groups. A nested scan through two groups costs much less than a scan through 32 distinct groups. Eight additional repeated-group microbenchmarks confirm that the unconditional hash table regresses these workloads:

| Isolated grouping workload | Baseline gas | Candidate gas | Additional gas |
| --- | ---: | ---: | ---: |
| 9 lines, two payout groups | 27,685 | 30,188 | 2,503 |
| 19 lines, two payout groups | 49,587 | 53,423 | 3,836 |
| 32 lines, two payout groups | 78,493 | 83,333 | 4,840 |
| 32 lines, one payout group | 67,470 | 82,265 | 14,795 |
| 64 lines, two payout groups | 149,417 | 157,873 | 8,456 |

These are isolated grouping-call costs rather than complete purchases. The result rules out adopting the unconditional candidate as a general improvement. A better next experiment keeps the existing scan while the number of groups is small and uses an index only when many distinct groups justify it. That adaptive approach has not been implemented or measured here. The dispersed-recipient savings in the preceding table must not be applied to the observed two-recipient carts or combined with the separate charge-compaction savings. Deliberately colliding hash buckets can also force repeated comparisons, so this candidate does not remove the reason to bound work. [Repeated-group measurements](data/cart-gas-2026-10-24/optimization-results.json).

A separate candidate reuses one scratch buffer when hashing each OrderLine. Its isolated 32-line measurement saves 19,811 gas, and 256 differential fuzz cases plus malformed-input comparisons preserve results. It has not been combined with the payout candidate in the complete-purchase measurements. The separate saving must not be added to the table as an observed transaction result. [Saved optimization methods and results](data/cart-gas-2026-10-24/optimization-results.json).

These experiments make 64 lines a reasonable next validation target for inexpensive off-chain or payment workloads. They do not justify changing the NFT-operation limit or advertising 64 customer items per transaction. Charge representation, production NFT costs, routes, and serialized transaction size still decide that capacity.

### Combine repeated purchases of the same listing where valid

OrderLine already carries quantity and total amount. Repeated purchases of the exact same off-chain or ERC-1155 listing can share one line when the listing terms, fulfillment recipient, accounting treatment, and downstream processing permit it. Add quantities and amounts with overflow checks, and rebuild actions and the platform-signed hashes. This can avoid repeating merchandise line records and ERC-1155 calls. The saved purchases already include ERC-1155 quantities of two and five in one line, so some quantity grouping is in use. [ICart.OrderLine](../src/cart/ICart.sol), [Cart._validateLineTerms](../src/cart/Cart.sol), [saved purchase quantities](data/cart-gas-2026-10-24/purchases.json).

This is conditional rather than a measured new optimization. Do not merge distinct listings, recipients, or fulfillment jobs. Combining transfers or mints can change receiver callback quantities and timing. Increasing an ERC-721 mint line's quantity still executes one mint call per unit and does not reduce its fulfillment-operation count. [Cart._validateActions](../src/cart/Cart.sol), [Cart._executeFulfillment](../src/cart/Cart.sol).

### Batch compatible ERC-1155 fulfillment

Cart currently performs one `safeTransferFrom` or `mintTo` call per ERC-1155 action. The repository's [RareERC1155](../src/token/ERC1155/RareERC1155.sol) exposes `mintBatchTo` and caps a batch at 100 strictly ascending, distinct token IDs. The [ERC-1155 interface](../lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol) also supports `safeBatchTransferFrom`. The existing [RareERC1155CheckoutExecutionModule](../src/marketplace/RareERC1155CheckoutExecutionModule.sol) demonstrates batch mint execution and balance checks, although its workflow differs from Cart.

Compatible mint actions can be grouped by collection and receiver. Compatible transfer actions also require the same seller. Duplicate IDs need combined quantities, with per-line accounting retained. This can reduce repeated collection checks, calls, and receiver hooks. It needs measurements with the real token, and explicit support for the batch selector rather than an assumption that every custom NFT supports it.

Batching changes callback behavior. A receiver that accepts `onERC1155Received` may reject `onERC1155BatchReceived`; callback timing and transfer events also change. Preserve per-line fulfillment events, inventory accounting, authorization, and failure attribution. If the operation policy counts external calls, batching lets more merchandise share a call, but internal per-token work still grows. Replacing 20 single calls with one batch must not be treated as proof that an arbitrary batch fits the gas budget.

The supported [ERC-721 mint interface](../src/collection/IERC721Mint.sol) exposes only `mintTo(address)`. Cart repeats it once per unit and records the returned IDs. There is no generic batch selector to substitute for that interface. A collection-specific batch mint would require explicit compatibility and token-ID/result guarantees. The prior live mint trace spent 565,266 gas inside one NFT mint call, so improving Cart bookkeeping alone cannot remove that external cost. [Cart._executeFulfillment](../src/cart/Cart.sol), [saved trace summary](data/cart-gas-2026-10-24/trace-summary.json).

## Checkout behavior that avoids customer dead ends

Use one checkout module to own order construction, quote freshness, capability checks, simulation, and partitioning. Its caller supplies the customer cart and delivery choices. It returns one ready transaction or a plan with several transactions and a specific reason. The caller does not need to know proof depth or the difference between line count and mint-call count.

Compute that plan as the cart changes, then repeat simulation against current state before submission. Simulate the actual caller, value, signatures, token contracts, router route, recipients, and active Cart implementation. A gas margin handles estimation variance; it cannot guarantee unchanged inventory or prices until inclusion. The earlier report's 12 million gas budget and 25% margin are suggested reserve policies, rather than measured universal capacity.

Try compaction and a simpler route before splitting. When splitting is necessary, quote each complete suborder independently, assign fresh order IDs and signatures, recompute routes and charges, and preserve customer-visible total pricing. Partitioning changes atomicity: the first purchase can succeed while a later one fails. It can also repeat fixed gas and order fees, so blindly splitting an existing signed transaction is incorrect. Preserve the remaining cart after partial completion and explain any additional cost before approval. [ICart.PurchaseOrder](../src/cart/ICart.sol), [Cart._validateOrderHashes](../src/cart/Cart.sol), [design's fixed quote semantics](cart-contract-design.md).

Until implementation changes pass representative combined-workload tests, the practical immediate improvements are to align preflight with supported execution, compact eligible fee lines before signing, and stop presenting raw order-line capacity as a customer item limit. A proposed larger count is an operating bound for measured workloads. Complete-payload gas and byte checks remain the decision for any particular purchase.

## Reproduce the saved-history analysis

Run this read-only script from the repository root. Structural grouping intentionally uses only fields preserved in the saved record.

```sh
python3 - <<'PY'
import collections
import json

with open('docs/data/cart-gas-2026-10-24/purchases.json') as source:
	records = json.load(source)
current = '0x6a667afbca403de9b2c5876534383c9c73c0db40'
shape_fields = (
	'listing_count', 'root_count', 'proof_nodes_total', 'max_proof_depth',
	'action_count', 'fulfillment_operations', 'route_commands',
	'unique_recipients', 'unique_settlement_currencies',
)
for name, sample in (
	('all', records),
	('current', [r for r in records if r['implementation'] == current]),
):
	kinds = collections.Counter(k for r in sample for k in r['line_kinds'])
	shapes = {
		(tuple(r['line_kinds']), tuple(r['line_quantities']),
		 *(r[field] for field in shape_fields))
		for r in sample
	}
	patterns = collections.Counter(
		(sum(k in (1, 2, 3, 4, 5) for k in r['line_kinds']),
		 r['line_kinds'].count(0), r['line_kinds'].count(6))
		for r in sample
	)
	print(name, 'purchases', len(sample), 'distinct hashes',
		len({r['hash'] for r in sample}), 'kinds', dict(kinds),
		'structural shapes', len(shapes), 'patterns', dict(patterns))
PY
```
