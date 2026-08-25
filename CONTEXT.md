# Commerce

The Commerce context describes authenticated purchases that combine monetary settlement with optional on-chain and off-chain fulfillment.

## Language

**Purchase Order**:
A platform-authorized purchase composed of one or more ordered charges and any associated fulfillment obligations.
_Avoid_: Cart transaction, checkout transaction

**Order Line**:
One independently identified quantity and charge within a Purchase Order, with its own final amount, settlement currency, and payment recipient. Merchandise lines may reference a Listing; shipping, platform compensation, and other platform-authorized charges remain peer Order Lines without one.
_Avoid_: Add-on, base amount

**Payer**:
The transaction caller whose native or ERC-20 assets fund a Purchase Order. The Cart always pulls
funds from `msg.sender`; no payer field or buyer-signed purchase authorization is part of the order.
The `PurchaseExecuted` event indexes the derived payer for reconciliation. The payer is independent
from every Fulfillment Action recipient and is not the beneficiary of favorable route execution.
A payment processor such as Coinflow may therefore be the payer without receiving transaction
residuals.
_Avoid_: Payment Source

**Fixed Quote**:
The platform-signed `paymentAmount` collected exactly from the Payer. It is the final transaction
price, not an unsigned spending limit. Every Order Line recipient receives its signed amount and
any favorable routing variance becomes Protocol Spread.
_Avoid_: Maximum payment, payment cap

**Sale Price**:
The customer-facing price assigned to merchandise. It may fund both Seller Proceeds and explicit
fees, so it need not equal the seller's proceeds floor. It is distinct from the Fixed Quote, which
is the final price for the complete Purchase Order, and from Protocol Spread, which arises only
from favorable route execution.
_Avoid_: Seller price, Listing amount

**Seller Proceeds Floor**:
The minimum proceeds per unit a seller authorizes for a Listing, denominated in its settlement
currency. A Purchase Order may pay the seller more than this floor but never less.
_Avoid_: Sale Price, gross price

**Currency Swap**:
A listing-less Order Line that exchanges part of the Purchase Order's payment currency for a
different settlement currency through the order-wide Universal Router route. Its amount and
recipient are fixed by the platform signature, and `CURRENCY_SWAP` records the fulfillment mode for
telemetry and reconciliation. The route may use exact-input or exact-output swap mechanics.
_Avoid_: ERC-20 swap

**Protocol Spread**:
Favorable routing variance captured by the configured protocol recipient under a Fixed Quote.
This includes excess settlement output from an exact-input route and unused payment input from an
exact-output route. It is never refunded to the Payer, seller, or fulfillment recipient.
_Avoid_: Refund, buyer surplus

**Fulfillment Action**:
An on-chain obligation associated with an Order Line and completed atomically as part of its Purchase Order. A line may have zero or more Fulfillment Actions.
_Avoid_: Fulfillment item, product

**Fulfillment Kind**:
The supported mechanism, if any, by which an Order Line is fulfilled. `NONE` means the line has no
fulfillment workflow; `OFF_CHAIN` means a successful settlement should trigger backend-managed
fulfillment; `CURRENCY_SWAP` identifies a listing-less currency conversion for reporting; the
remaining kinds are atomic on-chain NFT mechanisms.
_Avoid_: Listing kind, product kind, off-chain kind

**Listing**:
A concrete sale leaf committed by a seller-signed Listing Root. It has a seller-signed listing
identity and identifies on-chain or off-chain merchandise under stated settlement terms. A finite
Listing may be filled until its authorized quantity is exhausted, while an uncapped Listing may be
filled until its root is cancelled or expires, subject to the availability of its fulfillment
mechanism; on-chain merchandise additionally carries one or more Fulfillment Actions. Re-listing
returned inventory uses a fresh listing identity.
_Avoid_: order

**Listing Root**:
A seller-signed Merkle commitment whose nonce and deadline govern one or more Listing leaves. Each
selected Listing is submitted with an inclusion proof; a one-item Listing Root uses the same shape
with an empty proof.

**Authorization Witness**:
The seller Listing Root, selected Listing, and Merkle proof supplied with a Purchase Order. A
witness proves seller authorization but does not replace the platform-signed Purchase Order.

**Uncapped Listing**:
A Listing with no seller-authorized quantity ceiling. It may be used across multiple Purchase Orders for any Fulfillment Kind when the client considers repeated fulfillment appropriate.
_Avoid_: Unlimited listing

**SKU**:
An immutable, versioned platform-catalogue identifier signed by both the seller in a Listing and the platform in an Order Line. A SKU is never reused for a materially different merchandise definition or variant; changing commercial Listing terms does not by itself change the SKU.
_Avoid_: Product ID, mutable catalogue key
