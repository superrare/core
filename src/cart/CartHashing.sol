// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICart} from "./ICart.sol";

/// @notice Canonical EIP-712 struct hashing for Cart payloads.
/// @dev The single source of truth for the Cart typehashes, shared by the settlement contract and
///      the off-chain hashing helper so the two can never drift.
library CartHashing {
    bytes32 internal constant LISTING_TYPEHASH = keccak256(
        "Listing(bytes32 listingSalt,address seller,bytes32 sku,uint8 fulfillmentKind,address tokenContract,uint256 tokenId,address settlementCurrency,uint256 minimumUnitPrice,uint256 availableQuantity,address paymentRecipient)"
    );
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "PurchaseOrder(bytes32 orderId,address paymentCurrency,uint256 deadline,uint256 paymentAmount,bytes32 orderLinesHash,bytes32 payoutRouteHash,bytes32 fulfillmentActionsHash)"
    );
    bytes32 internal constant ORDER_LINE_TYPEHASH = keccak256(
        "OrderLine(bytes32 sku,bytes32 listingDigest,uint8 fulfillmentKind,uint256 quantity,address settlementCurrency,uint256 amount,address paymentRecipient)"
    );
    bytes32 internal constant ROUTE_TYPEHASH =
        keccak256("PayoutRoute(bytes commands,bytes[] inputs,uint256 routerValue)");
    bytes32 internal constant ACTION_TYPEHASH =
        keccak256("FulfillmentAction(uint256 lineIndex,uint256 quantity,address recipient)");
    bytes32 internal constant LISTING_ROOT_TYPEHASH =
        keccak256("ListingRoot(bytes32 listingsRoot,uint256 nonce,uint256 deadline)");

    function hashListingStruct(ICart.Listing calldata listing) internal pure returns (bytes32) {
        // Encode the fields in the exact order declared by LISTING_TYPEHASH.
        return keccak256(
            abi.encode(
                LISTING_TYPEHASH,
                listing.listingSalt,
                listing.seller,
                listing.sku,
                listing.fulfillmentKind,
                listing.tokenContract,
                listing.tokenId,
                listing.settlementCurrency,
                listing.minimumUnitPrice,
                listing.availableQuantity,
                listing.paymentRecipient
            )
        );
    }

    function hashOrderStruct(ICart.PurchaseOrder calldata order) internal pure returns (bytes32) {
        // Encode the fields in the exact order declared by ORDER_TYPEHASH.
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.orderId,
                order.paymentCurrency,
                order.deadline,
                order.paymentAmount,
                order.orderLinesHash,
                order.payoutRouteHash,
                order.fulfillmentActionsHash
            )
        );
    }

    function hashOrderLines(ICart.OrderLine[] calldata lines) internal pure returns (bytes32) {
        // Hash each line first so the array can be included in the signed order as one value.
        bytes32[] memory hashes = new bytes32[](lines.length);
        for (uint256 i = 0; i < lines.length; ++i) {
            // Hash one line with the canonical OrderLine type hash.
            hashes[i] = keccak256(
                abi.encode(
                    ORDER_LINE_TYPEHASH,
                    lines[i].sku,
                    lines[i].listingDigest,
                    lines[i].fulfillmentKind,
                    lines[i].quantity,
                    lines[i].settlementCurrency,
                    lines[i].amount,
                    lines[i].paymentRecipient
                )
            );
        }
        // Concatenate the line hashes and hash the resulting byte sequence.
        return _concatHash(hashes);
    }

    function hashPayoutRoute(ICart.PayoutRoute calldata route) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(ROUTE_TYPEHASH, keccak256(route.commands), _hashBytesArray(route.inputs), route.routerValue)
        );
    }

    function hashFulfillmentActions(ICart.FulfillmentAction[] calldata actions) internal pure returns (bytes32) {
        // Hash each action before including the action array in the signed order.
        bytes32[] memory hashes = new bytes32[](actions.length);
        for (uint256 i = 0; i < actions.length; ++i) {
            // Hash one fulfillment action with the canonical action type hash.
            hashes[i] =
                keccak256(abi.encode(ACTION_TYPEHASH, actions[i].lineIndex, actions[i].quantity, actions[i].recipient));
        }
        // Concatenate the action hashes and hash the resulting byte sequence.
        return _concatHash(hashes);
    }

    function hashListingRootStruct(ICart.ListingRoot calldata root) internal pure returns (bytes32) {
        // Hash the seller's Merkle root, nonce, and deadline as one typed struct.
        return keccak256(abi.encode(LISTING_ROOT_TYPEHASH, root.listingsRoot, root.nonce, root.deadline));
    }

    /// @dev The extra hash makes the leaf domain distinct from an internal Merkle node while
    ///      retaining the OpenZeppelin sorted-pair proof convention.
    function hashListingLeaf(bytes32 listingDigest) internal pure returns (bytes32) {
        // Add the leaf hash so a listing digest cannot be confused with an internal Merkle node.
        return keccak256(abi.encode(listingDigest));
    }

    function _hashBytesArray(bytes[] calldata values) private pure returns (bytes32) {
        // Hash each dynamic byte value before hashing the array body.
        bytes32[] memory hashes = new bytes32[](values.length);
        for (uint256 i = 0; i < values.length; ++i) {
            // Replace each byte value with its keccak256 digest.
            hashes[i] = keccak256(values[i]);
        }
        // Return the hash of the ordered element digests.
        return _concatHash(hashes);
    }

    /// @dev Equivalent to `keccak256(abi.encodePacked(hashes))`, hashing the array body in place
    ///      instead of copying it into a fresh buffer first.
    function _concatHash(bytes32[] memory hashes) private pure returns (bytes32 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Skip the array length and hash all 32-byte elements in order.
            result := keccak256(add(hashes, 0x20), shl(5, mload(hashes)))
        }
    }
}
