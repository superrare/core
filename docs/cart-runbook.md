# Operate the Cart administrative controls

Use this runbook for on-chain administrative changes and seller authorization invalidation. Execute owner calls against the Cart proxy on the intended chain. Use the configured owner wallet or multisig. Keep transaction hashes, before-and-after reads, and the reason for each change in the operational record.

The signed spread-recipient source change has not been deployed. Confirm the deployed implementation and ABI before using these procedures. The [deployment index](cart.md#deployment-records) links the recorded Sepolia state. Constructor errors and transaction-builder payload retries are outside this runbook.

## Rotate the platform signer

1. Read `owner()`, `platformSigner()`, `paused()`, and `DOMAIN_SEPARATOR()` from the proxy. Confirm the chain and proxy address.
2. Prepare the replacement signing account and update the trusted signing service. For an ERC-1271 signer, simulate signature validation through the complete checkout.
3. Stop releasing quotes from the retiring signer. If execution must stop during the transition, call `setPaused(true)` from the owner and confirm `paused()` returns `true`.
4. Call `setPlatformSigner(newSigner)` from the owner. Confirm the `PlatformSignerUpdated` event and `platformSigner()` value.
5. Rebuild and sign outstanding quotes with the new signer. Simulate a representative complete checkout using the actual payer and funding.
6. If paused, call `setPaused(false)` from the owner after the signing service and consumers use the new signer. Confirm `paused()` returns `false`.

Cart validates orders against the current signer at execution. Rotating the signer makes the retiring signer's outstanding quotes fail signature validation. Rotation does not erase those signatures; rotating back can make unexpired, unexecuted quotes valid again. Cart accepts the configured signer address without checking that it can validate orders. Verify the replacement before resuming checkout.

## Pause and resume checkout

1. Call `setPaused(true)` from the owner to stop new `executePurchase` calls. Confirm the `ContractPausedUpdated` event and `paused()` read.
2. Diagnose the incident and correct the signer, backend behavior, or implementation as needed. Keep quote issuance stopped when those quotes cannot execute safely.
3. Simulate a representative complete checkout against the intended resumed state.
4. Call `setPaused(false)` from the owner and confirm the `ContractPausedUpdated` event and `paused()` read. Resume quote release.

Pausing does not cancel orders or seller authorizations. Unexpired signatures can execute after resumption if all other checks still pass. Seller cancellation and nonce invalidation remain available while paused. A failed checkout reverts its token transfers, NFT fulfillment, inventory reservations, and replay mark together. The transaction sender still pays gas.

## Change the treasury for future quotes

1. Update the trusted signing service's allowed treasury address.
2. Put the new nonzero address in `PurchaseOrder.spreadRecipient` before signing each new checkout.
3. Simulate complete checkouts for the supported currencies and reconcile `ProtocolSpreadCaptured` events with the signed recipient.

There is no global recipient setter. Outstanding quotes retain their signed recipient. If that recipient cannot receive a payout, issue a replacement quote with a suitable recipient and arrange for the old quote to expire or become unusable through signer rotation. Issuing a replacement alone does not cancel the original quote. Use order identity and expiry controls in the signing service to prevent duplicate fulfillment. There is no per-order administrative cancellation.

## Transfer ownership

1. Read `owner()` and verify that the replacement owner can execute calls on the intended chain.
2. Submit `transferOwnership(newOwner)` from the current owner. This inherited Ownable version transfers ownership immediately, without a separate acceptance transaction.
3. Confirm `OwnershipTransferred` and `owner()`. Verify the new owner's ability to operate the intended multisig or wallet workflow before retiring the old workflow.

Ownership transfer does not change the platform signer or any signed spread recipient. `renounceOwnership()` permanently removes access to owner-only signer rotation, pause controls, and upgrade authorization. Do not use renunciation as a handoff procedure.

## Upgrade the implementation

1. Pin the reviewed source revision and build configuration. Verify the tests, storage compatibility, runtime bytecode, and matching executor and helper artifacts for that revision.
2. Read the proxy's owner, signer, pause state, domain separator, routing dependencies, and ERC-1967 implementation slot. Record representative inventory, cancellation, nonce, and replay state for postflight comparison.
3. Coordinate the ABI and signing-service transition. Pause checkout if the transition requires execution to stop. Do not treat pause as signature invalidation.
4. Simulate the complete upgrade and a representative checkout against the target chain state. Use `upgradeTo(newImplementation)` or `upgradeToAndCall(newImplementation, data)` from the owner through the proxy. Include initializer data only when the reviewed migration explicitly requires it.
5. Confirm the implementation slot and deployed runtime bytecode. Confirm that ownership, signer, pause state, routing dependencies, domain separator, inventory, seller invalidation, and replay state match the intended migration.
6. Update verified helper addresses, generated bindings, and the signing service together. Simulate a complete checkout, then resume execution and quote release when appropriate.

For the signed spread-recipient migration, deploy matching CartPayments, Cart, CartLens, and CartHashes artifacts. Preserve the existing proxy and route policy when the reviewed change permits it. Keep the retired global recipient slot reserved and unchanged. Do not reuse the older payment executor or hashing helper. Rebuild and sign old checkout payloads using the new order type. Seller Listing and Listing Root typehashes and the EIP-712 domain remain unchanged.

`CartFreeListingUpgrade.s.sol` and `upgradeCartFreeListings.py` deploy the replacement executor and current helpers. Their historical names do not limit them to the old free-listing ABI. Review and simulate the exact artifacts before broadcasting. The implementation-only helper is disabled for this migration because the old executor is incompatible.

A rollback is another owner-authorized upgrade. Assess storage writes, executor compatibility, and signature validity against the proposed rollback target. Reinstalling an older implementation can restore acceptance of old unexpired order signatures. Do not assume an implementation rollback reverses completed purchases.

## Invalidate seller authorizations

Use the seller account that signed the affected authorizations:

1. To revoke a whole root, call `cancelListingRoot(rootDigest)` with the root's typed-data digest. Confirm `ListingRootCancelled` and `cancelledListingRoots(seller, rootDigest)`.
2. To revoke one listing across roots, call `cancelListing(listingDigest)`. Confirm `ListingCancelled` and `cancelledListings(seller, listingDigest)`.
3. To invalidate every root signed with the seller's current nonce, call `invalidateListingNonce()`. Confirm `ListingNonceInvalidated` and the incremented `listingNonces(seller)` value.

These controls remain available while paused. Cancellation does not reverse completed purchases or restore consumed inventory. Replace revoked authorizations through the normal seller-signing flow with the appropriate nonce and listing identity.

## Handle failures without a recovery function

Cart has no general rescue or withdrawal function, no deferred payout queue, and no per-order administrative cancel function. A failed purchase rolls back atomically. Diagnose the revert and issue a valid quote after correcting the underlying condition. Verify receipt status and `executedOrderIds(orderId)` before retrying an uncertain submission. A successful purchase cannot execute again under the same order ID.

Tracked preexisting balances are protected by settlement baselines and are not distributed as order spread. Do not send funds directly to Cart as a recovery step. Recovering accidentally stranded assets would require a separately reviewed implementation change. Refunds and reversal of completed off-chain commerce are application operations, not Cart administrative functions.
