# Cart resource policy

Updated October 26, 2026. This describes workspace source, not deployed contract behavior.

Cart, CartLens, and CartRoutePolicy impose no numerical resource caps on Order Lines, Fulfillment Actions, expanded NFT operations, Merkle-proof depth, or route commands and inputs. The backend transaction builder owns admission policy. The transaction gas limit still bounds execution.

Cart requires at least one line, `listings.length <= lines.length`, and `listingRoots.length <= listings.length`. It requires matching root/signature arrays and listing/index/proof arrays. These relationships remain structural checks. Each supplied listing must be used, and each action must point to an on-chain line with valid quantity and recipient. Action quantities must exactly cover each line. An ERC-721 transfer still requires one action of quantity one.

Platform signatures bind the Purchase Order's exact line, route, and action hashes. Seller signatures and Merkle proofs authorize Listings separately. Witnesses are not directly committed by the platform signature, so callers can supply alternative witnesses that must still pass validation. Pausing, deadlines, replay prevention, seller inventory, route command allowlisting, forbidden command flags, exact funding, payouts, and balance isolation remain enforced on-chain.

CartRoutePolicy requires nonempty commands and equal command/input counts when invoked. Cart permits a direct-payment order with an empty route and zero router value. Router input decoding remains the router's responsibility. Permit2 field widths remain protocol constraints.

Line count alone cannot bound mint quantities, recipient splits, swap hops, proof bytes, contract-wallet signatures, or gas used by token and receiver contracts. Two fee lines are a benchmark shape, not a protocol requirement. See the [backend builder handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend) for admission and checkout behavior.

Removing caps changes no storage layout or purchase argument types, EIP-712 types, or event schemas. The obsolete resource-limit errors and CartRoutePolicy's public `MAX_ROUTE_COMMANDS()` getter are removed from the ABI. Update generated bindings and remove callers of that getter. Activating this behavior requires a new uncapped route policy, a CartPayments executor constructed with that policy, a Cart implementation upgrade referencing both, and a replacement CartLens. An older configured route policy can still enforce its own limit.
