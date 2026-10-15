// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

import {CartHashing} from "./CartHashing.sol";
import {ICart} from "./ICart.sol";

/// @notice Stateless EIP-712 hashing helper for Cart clients.
/// @dev These digests are only ever needed off-chain, so they live here rather than in Cart, where
///      their calldata decoders would consume the settlement contract's EIP-170 budget. Clients that
///      hash locally do not need this contract at all; pass `Cart.DOMAIN_SEPARATOR()` to the
///      domain-bound helpers.
contract CartHashes {
    function hashListing(bytes32 domainSeparator, ICart.Listing calldata listing) external pure returns (bytes32) {
        // Hash the listing struct and bind it to the supplied Cart domain.
        return ECDSA.toTypedDataHash(domainSeparator, CartHashing.hashListingStruct(listing));
    }

    function hashListingRoot(bytes32 domainSeparator, ICart.ListingRoot calldata root) external pure returns (bytes32) {
        // Hash the listing root struct and bind it to the supplied Cart domain.
        return ECDSA.toTypedDataHash(domainSeparator, CartHashing.hashListingRootStruct(root));
    }

    function hashListingLeaf(bytes32 listingDigest) external pure returns (bytes32) {
        // Apply the same leaf hash that Cart uses for Merkle proof verification.
        return CartHashing.hashListingLeaf(listingDigest);
    }

    function hashOrder(bytes32 domainSeparator, ICart.PurchaseOrder calldata order) external pure returns (bytes32) {
        // Hash the order struct and bind it to the supplied Cart domain.
        return ECDSA.toTypedDataHash(domainSeparator, CartHashing.hashOrderStruct(order));
    }

    function hashOrderLines(ICart.OrderLine[] calldata lines) external pure returns (bytes32) {
        // Return the canonical array hash used inside a PurchaseOrder.
        return CartHashing.hashOrderLines(lines);
    }

    function hashPayoutRoute(ICart.PayoutRoute calldata route) external pure returns (bytes32) {
        return CartHashing.hashPayoutRoute(route);
    }

    function hashFulfillmentActions(ICart.FulfillmentAction[] calldata actions) external pure returns (bytes32) {
        // Return the canonical action array hash used inside a PurchaseOrder.
        return CartHashing.hashFulfillmentActions(actions);
    }
}
