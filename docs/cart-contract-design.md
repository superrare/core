# Generic Atomic Commerce Cart

## Purpose

The cart is a generic atomic settlement contract for on-chain and off-chain commerce. It authenticates platform Purchase Orders and seller Listings, collects one input currency, routes and pays peer Order Lines, performs supported NFT fulfillment, and emits authoritative reconciliation events. It does not interpret catalogue metadata, calculate taxes or discounts, or calculate royalties. Route output above signed line obligations is sent to the configured protocol recipient.

See [Commerce language](../CONTEXT.md), [ADR 0001](./adr/0001-cart-route-policy.md), and [ADR 0002](./adr/0002-uups-cart-for-stable-approvals.md).

## Decision: caller-funded execution

The pre-deployment design removes seller-submitted accept-offer transactions and buyer-signed
purchase details. A Purchase Order is authorized by the platform signature, its referenced Listings
are authorized by sellers, and `msg.sender` is the payer. `paymentSource` is intentionally absent
from the signed order and calldata because it cannot differ from the caller. The `PurchaseExecuted`
event still indexes the derived payer for reconciliation. Fulfillment recipients remain independent
of the payer and are specified per `FulfillmentAction`.

## Authorities

Two signatures and the transaction caller protect the transaction:

- The seller signs one reusable `ListingRoot` authorizing a set of Listing leaves. Each leaf
  commits to a SKU, inventory, minimum proceeds, and fulfillment terms. A singleton listing is the
  same shape: a one-leaf root with an empty proof.
- The platform signs the complete Purchase Order, including ordered lines, payout routes, and fulfillment actions.
- The transaction caller is the payer. Native input comes from `msg.value`; ERC-20 input uses the
  caller's ordinary Cart allowance and exact `transferFrom(msg.sender, Cart, order.paymentAmount)`.
  There is no buyer-signed purchase-details message and no relayed payer authorization.

The configured platform signer and Listing sellers may be EOAs or ERC-1271 contract accounts. A
processor such as Coinflow can still be the transaction caller; any customer authorization remains
an off-chain processor responsibility.

## Data Model

```solidity
enum FulfillmentKind {
    NONE,
    OFF_CHAIN,
    ERC721_TRANSFER,
    ERC1155_TRANSFER,
    ERC721_MINT_TO,
    ERC1155_MINT_TO,
    CURRENCY_SWAP
}

struct Listing {
    bytes32 listingId;
    address seller;
    bytes32 sku;
    FulfillmentKind fulfillmentKind;
    address tokenContract;
    uint256 tokenId;
    address settlementCurrency;
    uint256 minimumUnitPrice;
    // Zero means uncapped; a positive value is a finite authorized quantity.
    uint256 availableQuantity;
    address paymentRecipient;
}

struct OrderLine {
    bytes32 sku;
    bytes32 listingHash;
    FulfillmentKind fulfillmentKind;
    uint256 quantity;
    address settlementCurrency;
    uint256 amount;
    address paymentRecipient;
}

struct PayoutRoute {
    bytes commands;
    bytes[] inputs;
}

struct FulfillmentAction {
    uint256 lineIndex;
    uint256 quantity;
    address recipient;
}

struct PurchaseOrder {
    bytes32 orderId;
    address paymentCurrency;
    uint256 paymentAmount;
    uint256 deadline;
    bytes32 orderLinesHash;
    bytes32 payoutRouteHash;
    bytes32 fulfillmentActionsHash;
}

```

Execution adds only authorization witnesses around this same Purchase Order:

- `ListingRoot` contains the seller's nonce/deadline and a seller-signed Merkle root of Listing
  digests. The caller supplies each selected Listing and its proof; roots are reusable across
  purchases and can be cancelled as a whole.
- The root path is batch-native for listings, but on-chain execution remains bounded by the Cart's
  order-line and fulfillment-operation limits. A large root is assembled off-chain; only the
  selected leaves and proofs are sent in each transaction.

`paymentAmount` is part of the platform signature and is the fixed customer quote, not a caller-chosen
spending limit. Cart collects it exactly. The complete total has no base amount: every charge is a peer
Order Line. Royalties, shipping, handling, seller revenue, and platform compensation are explicit
lines.

Arrays are order-sensitive. EIP-712 array hashes are hashes of ordered element hashes; dynamic `bytes` and `bytes[]` members are hashed canonically before inclusion in their containing struct hash. The EIP-712 domain binds signatures to the chain and cart proxy.

The cart exposes `DOMAIN_SEPARATOR()` and otherwise leaves digest construction to callers, since signers build these payloads off-chain. Clients that cannot hash typed data locally can use the stateless `CartHashes` helper; it and the cart both draw their typehashes from the shared `CartHashing` library, so the two cannot drift.

`CartLens` is a separately deployed, stateless read boundary for integrations. It combines the Cart's public state into Listing status (capacity, root nonce, and root deadline), previews routes through the configured `CartRoutePolicy`, and returns structured preflight results for the Purchase Order envelope and root-authorized Listings. Lens results are advisory: `executePurchase` remains the authority and repeats all checks against current state. Keeping these helpers outside Cart preserves settlement bytecode headroom and lets read APIs evolve without changing approvals, storage, signatures, or the proxy.

## Purchase Order Rules

- `orderId` is a nonzero, globally unique one-time nonce. `executedOrderIds[orderId]` prevents replay.
- The transaction caller is always the payer. Native input requires `msg.value == order.paymentAmount`;
  ERC-20 input uses the caller's ordinary Cart allowance. Cart pulls exactly the signed amount.
- The configured platform signer validates the Purchase Order through OpenZeppelin `SignatureChecker`.
- The deadline is inclusive through its final valid timestamp and expired thereafter.
- There are 1–20 Order Lines.
- Supplied Listings cannot exceed Order Lines, and supplied Listing Roots cannot exceed Listings.
- The Purchase Order has one order-wide Payout Route covering the complete settlement-currency basket.
- SKU, amount, quantity, and payment recipient are nonzero.
- Duplicate SKUs and duplicate Listing references are permitted.
- A successful transaction marks the order executed before external calls; any later revert rolls that write back.

## Listing Rules

A Listing is never pre-registered. The caller supplies each deduplicated Listing and its ListingRoot
inclusion proof; the seller's root signature is supplied once per root. `listingHash` is the complete
EIP-712 Listing digest. Every supplied Listing must be referenced, every nonzero Order Line hash must
resolve exactly once, and zero is reserved for platform-only lines.

Each supplied Merkle proof is limited to 64 sibling hashes so malformed witnesses cannot force
unbounded proof processing.

- The Listing digest is the immutable identity of its exact terms. Any edit signs a new leaf and,
  when needed, a new root.
- `listingId` is a seller-signed identity for one listing instance. Re-listing returned inventory
  with otherwise identical terms uses a fresh `listingId`, producing a fresh Listing digest and
  fill bucket.
- Fill state is keyed by the Listing digest; the same leaf can be included in multiple reusable roots
  without creating separate inventory buckets.
- `cancelListingRoot(rootDigest)` invalidates the seller's entire Listing Root, including singleton roots.
- `cancelListing(listingDigest)` invalidates one exact Listing across every root that contains it.
- `invalidateListingNonce()` invalidates all Listings signed with an older seller nonce.
- Seller invalidation remains callable while purchases are paused.
- Seller root cancellation and nonce invalidation are non-reentrant; fulfillment callbacks cannot mutate seller invalidation state during an active purchase.
- The Listing Root must be unexpired and on the seller's current nonce. A positive `availableQuantity` must have remaining
  quantity; zero means the Listing is uncapped until its deadline or root cancellation.
- The line SKU, settlement currency, and payment recipient must equal the Listing values.
- `line.amount >= listing.minimumUnitPrice * line.quantity` with checked arithmetic.
- For finite Listings, cumulative requested quantity across every line referencing the Listing must fit its remaining
  authorized quantity. Uncapped Listings do not use `filledQuantity` as a limit.
- `filledQuantity` records cumulative fulfilled quantity for both finite and uncapped Listings. It is observational for
  uncapped Listings and does not prevent a Listing from becoming valid again if its underlying fulfillment becomes
  available before the deadline.

Fulfillment-kind-specific validation:

- `NONE`: there is no fulfillment workflow, token contract and token ID are zero, and there are no Fulfillment Actions. This covers services, shipping-only lines, fees, royalties, and other charges without a fulfillment job.
- `OFF_CHAIN`: token contract and token ID are zero and there are no Fulfillment Actions; a successful `OrderLineSettled` event is the backend trigger for physical merchandise or another off-chain fulfillment workflow.
- `ERC721_TRANSFER`: a finite Listing has available and purchased quantity of one; an uncapped Listing has zero
  available quantity. The native `safeTransferFrom` call is authoritative for ownership and approval at execution.
- `ERC1155_TRANSFER`: the native `safeTransferFrom` call is authoritative for seller balance and approval at execution.
- `ERC721_MINT_TO`: token ID is zero; the seller remains collection owner; the cart is an approved minter; `mintTo(address)` is called once per unit.
- `ERC1155_MINT_TO`: the seller remains collection owner; the cart is an approved minter; `mintTo(address,uint256,uint256)` is called once per action.
- `CURRENCY_SWAP` is not valid on a seller Listing. It is a listing-less Order Line whose settlement
  currency differs from the payment currency and whose fulfillment mode is retained in reconciliation events.

The supported mint selectors are exact known interfaces. A collection with an incompatible selector or behavior reverts; arbitrary mint schemes and Universal Router NFT-marketplace commands are not supported.

## Fulfillment Rules

- Each action has a valid line index, nonzero quantity, and nonzero recipient.
- An action recipient is independent of the payer (`msg.sender`); one Purchase Order may deliver
  different fulfillment units to different recipients.
- Every on-chain Listing line has one or more actions; off-chain and platform-only lines have none.
- Action quantities for each line sum exactly to the line quantity.
- A Purchase Order contains at most 20 Fulfillment Actions.
- An ERC-721 transfer has one action of quantity one.
- ERC-1155 quantities and ERC-721 mint quantities may be divided among recipients.
- There are at most 20 native fulfillment operations per Purchase Order. Each ERC-721 mint call consumes one operation; each ERC-721 transfer, ERC-1155 transfer, and ERC-1155 mint call consumes one.
- NFT owners and collection creators approve the cart proxy directly. The cart performs native transfers and supported mint calls itself.

## Currency Funding and Routing

Native ETH is represented by `address(0)` and is supported as input or settlement currency. WETH remains a distinct ERC-20.

- Native input requires `msg.value == order.paymentAmount`.
- ERC-20 input requires `msg.value == 0` and calls `transferFrom(msg.sender, Cart,
  order.paymentAmount)` against the caller's ordinary Cart allowance.
- Fee-on-transfer and rebasing currencies are unsupported.
- Payment and settlement currencies are supplied by the client and authorized by the platform-signed order; native ETH is represented by `address(0)`. Intermediate route-token selection is backend-owned and is covered by the platform signature; Cart enforces that every command starts in the payment currency and ends in one of the signed settlement currencies.
- Each order carries one `PayoutRoute` for the complete order.
- If every line settles in the payment currency, commands and inputs must both be empty. Mixed direct and routed lines use one route for the routed settlement-token basket.
- The order-wide route contains at most 32 commands and 32 command inputs.
- Swap mode is derived only from the validated Universal Router commands.
- New orders carry one order-wide route. Exact-input plans fix input spend, require each aggregate
  settlement currency to meet the signed line basket, and send favorable output surplus to the
  configured protocol recipient. The client quotes and signs the complete command sequence.
- Exact-output routes require each aggregate settlement-token obligation and send unused input to the
  configured protocol recipient as Protocol Spread.
- The protocol surplus recipient is initialized to the Cart owner and can be rotated by the owner;
  it receives output-token surplus, while line recipients receive exactly their signed amounts.
- The signed `paymentAmount` is the final customer charge. Exact-input excess output and exact-output
  unused input are Protocol Spread; neither is refunded to the payer or processor.
- Failed transactions rely on EVM rollback rather than compensating transfers.

The Universal Router and Permit2 are configured once with no runtime dependency setters. Only the platform signer is rotatable. Cart does not spend runtime bytecode defending trusted deployment and administrative calls from bad configuration: dependency addresses are validated by deployment tooling, and the owner may set any platform signer (including an address that cannot validate orders). A bad configuration can make purchases unavailable but cannot bypass signature or settlement invariants. Cart's settlement balance invariant covers the signed payment currency and every signed line settlement currency; intermediate route-token selection is a client and backend responsibility.

### CartRoutePolicy

`CartRoutePolicy` adapts the Liquid Router's proven default-deny policy. It is command-shape restricted: it accepts explicitly decoded V2/V3 exact-input and exact-output swaps plus V4 swap plans containing exactly one swap, one `SETTLE_ALL`, and one `TAKE_ALL` action. Every other Universal Router command or nested V4 action is rejected. It rejects command flags and partial failure, constrains outputs to the cart, requires the cart as payer, and enforces that each path starts in the payment currency and ends in one of the signed settlement currencies. Intermediate route-token selection is a backend responsibility covered by the platform signature. V3 and V4 exact-output paths are validated in their required reverse order.

The policy is deployed as its own stateless contract and referenced by a cart implementation immutable rather than compiled into the cart. The call boundary keeps the policy out of the cart's EIP-170 budget and gives the cart a `try`/`catch` seam that attributes a rejected route to the Order Line that produced it. Because the reference is an immutable rather than storage, replacing the policy still requires an audited implementation upgrade.

Permit2 configuration is performed by the cart, not embedded in route commands. Temporary token and Permit2 allowances are limited to transaction-local funds, cleared after routing, and verified as zero. A successful Purchase Order restores the signed payment and line settlement currency balances in Cart to their pre-transaction baselines, preventing accidental Cart funds from subsidizing a purchase. Universal Router balances for those same currencies may decrease, allowing a route to consume publicly extractable pre-existing router funds, but may not increase; the transaction may not strand new ETH or settlement currencies in the router. Intermediate route tokens are not part of Cart's on-chain balance surveillance.

The Universal Router address is configured once. Supporting another router version or command layout requires an audited cart implementation upgrade.

## Atomic Execution

The non-reentrant execution sequence is:

1. Validate the complete Purchase Order, Listings, the order-wide route, actions, currencies, and local cap shape.
2. Mark the order executed and reserve all Listing quantities.
3. Collect the signed `paymentAmount` from the caller's native value or ordinary Cart allowance.
4. Execute the one order-wide route, validate each aggregate output basket, and forward surplus to the protocol recipient.
5. Execute every Fulfillment Action.
6. Pay every Order Line recipient.
7. Send unused input to the protocol recipient as Protocol Spread.
8. Emit reconciliation events.

Any validation, route, fulfillment, payout, or spread-capture failure reverts the complete transaction, including execution state, Listing fills, token movement, and earlier payments.

## Failure Diagnosis

Reverted logs do not survive, so indexed custom errors are authoritative:

```solidity
enum FailureStage {
    FUNDING,
    ROUTING,
    PAYOUT,
    SPREAD
}

error OrderLineFailed(uint256 lineIndex, FailureStage stage, bytes reason);
error FulfillmentActionFailed(uint256 lineIndex, uint256 actionIndex, bytes reason);
```

Low-level router and mint failures preserve nested revert data. A backend simulates with `eth_call`, decodes the failing index, repairs or removes the item, and obtains a new platform signature. Seller Listings remain reusable and do not require re-signing unless their terms change.

## Reconciliation Events

```solidity
event PurchaseExecuted(
    bytes32 indexed orderId,
    address indexed payer,
    address indexed paymentCurrency,
    uint256 paymentAmount
);

event ProtocolSpreadCaptured(
    bytes32 indexed orderId,
    address indexed currency,
    address indexed recipient,
    uint256 amount
);

event OrderLineSettled(
    bytes32 indexed orderId,
    uint256 indexed lineIndex,
    bytes32 indexed sku,
    bytes32 listingHash,
    uint256 quantity,
    address settlementCurrency,
    uint256 amount,
    address paymentRecipient,
    FulfillmentKind fulfillmentKind
);

event FulfillmentActionExecuted(
    bytes32 indexed orderId,
    uint256 indexed lineIndex,
    uint256 indexed actionIndex,
    FulfillmentKind fulfillmentKind,
    address target,
    address recipient,
    uint256 quantity,
    uint256 tokenId,
    uint256 unitIndex
);
```

Each line recipient receives exactly its signed `amount`. `ProtocolSpreadCaptured` separately records favorable execution variance by currency for telemetry, reporting, and reconciliation. Successful logs are authoritative because they survive only complete atomic execution. Off-chain workers use `(chainId, cartProxy, orderId, lineIndex)` as their idempotency key. `OFF_CHAIN` lines emit `OrderLineSettled` without a Fulfillment Action event and are the backend trigger for external work; `NONE` and `CURRENCY_SWAP` lines emit the same settlement event but require no external fulfillment job. Each Fulfillment Action log identifies its recipient, fulfilled quantity, and token ID; repeated ERC-721 mints use `unitIndex` to distinguish the individual operations within one action.

## Administration and Upgrade Safety

The cart is a UUPS proxy owned by the protocol multisig. OpenZeppelin's inherited linear storage and Cart's namespaced storage must be preserved across upgrades. Cart-owned state is organized into three ERC-7201 namespaces: `CartConfig` for configuration and pause state, `CartListings` for seller Listing state, and `CartSettlement` for Purchase Order replay state. The reviewed pre-deployment baseline is documented in `src/cart/Cart.storage-layout.json` and exercised by the proxy-upgrade canary in `src/test/cart/CartStorageLayout.t.sol`; obsolete offer-authorization fields are intentionally absent because no deployment compatibility is required. Owner powers are limited to platform-signer rotation, pause/unpause, and implementation upgrades. Pausing blocks only Purchase Order execution; Listing Root cancellation and nonce invalidation remain available.

Every cart implementation is constructed with the route policy address, so each upgrade names the policy it was audited against.

The proxy address remains the EIP-712 verifying contract and approval target. Upgrades preserve domain name/version unless invalidating pending signatures is intentional, and must preserve execution, Listing fill, cancellation, nonce, and configuration storage.

## Verification Expectations

Implementation acceptance includes unit, invariant, fuzz, and fork coverage for:

- EIP-712 EOA and ERC-1271 platform and seller signatures; altered, malformed, expired, cross-chain, and cross-contract payloads.
- Purchase Order replay and rollback after every failure stage.
- Whole Listing Root cancellation, exact Listing cancellation, bulk nonce invalidation, deliberate
  re-listing with a fresh `listingId`, partial fills, duplicate Listing references, races for final
  inventory, and fill rollback.
- Every Fulfillment kind, ownership transition, approval loss, mint incompatibility, recipient splitting, and the 20-operation cap.
- Empty direct routes and allowed V2/V3 exact-input and exact-output routes.
- Default rejection of every other Universal Router command, flag, nested action, recipient, currency, and route shape.
- Native/ERC-20 inputs and outputs, exact signed funding, output and input Protocol Spread, failed native recipients, fee-on-transfer tokens, temporary allowance cleanup, and balance isolation.
- Indexed error attribution for every line, action, and failure stage.
- Event completeness and off-chain idempotency keys.
- Pause behavior, seller invalidation while paused, signer rotation, UUPS authorization, storage preservation, and EIP-712 compatibility across upgrades.
- Mainnet and target-chain fork execution against the configured Universal Router, Permit2, and WETH.
