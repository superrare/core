# Bind the spread recipient to each signed checkout

## Decision

`PurchaseOrder` includes a required nonzero `spreadRecipient` immediately after `paymentAmount`. The platform signature binds that address. Cart sends every supported-currency surplus remaining after exact line payouts to that recipient, including unused input, excess output, ETH, and WETH.

Remove the global recipient getter, setter, and configuration-change event. Keep its old storage slot reserved and unused so existing proxy state does not move. There is no default recipient or zero-address fallback.

## Reason

The fixed quote already binds the payment amount, line obligations, route, and fulfillment actions. Binding the surplus destination makes the quote's settlement terms complete. An owner transaction cannot redirect the spread of an outstanding quote after signing.

The platform signer can authorize any nonzero spread destination. The signing service must enforce its treasury policy. This expands the signer's explicit authority over spread destinations. The previous global setting kept that authority with the contract owner and let treasury rotation redirect all outstanding orders.

## Consequences

Treasury rotation changes newly signed quotes. Outstanding quotes retain their signed recipient until execution or expiry. A rejecting native recipient or incompatible token recipient can cause atomic checkout failure; no deferred payout or administrative rerouting exists.

This changes the Purchase Order ABI and EIP-712 typehash. Old checkout payloads must be rebuilt and signed again. The EIP-712 domain, seller Listing and Listing Root types, inventory state, and replay state remain unchanged. Existing seller authorizations remain subject to their deadlines, nonces, cancellation, and inventory checks.

A rollout requires matching CartPayments, Cart, CartLens, and CartHashes artifacts plus regenerated client bindings. The previous executor's settlement ABI is incompatible. This source change does not deploy or upgrade any contracts.

## Route boundary

This decision supersedes only the global recipient aspect of [ADR 0001](0001-cart-route-policy.md). Router inputs remain opaque and signed. The signed spread recipient controls Cart's final residual transfers; it does not constrain recipients encoded inside Universal Router inputs. Builders must still return route output and refunds to Cart and simulate the complete checkout.
