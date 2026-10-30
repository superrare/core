// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "./CartFixture.sol";
import {ICart} from "../../cart/ICart.sol";

/// @notice Shared Merkle authorization builder for the gas benchmark suites.
abstract contract CartListingGasFixture is CartFixture {
    function sharedRoot(ICart.Listing[] memory listings)
        internal
        returns (ICart.ListingPurchaseAuthorization memory auth)
    {
        uint256 width = 1;
        uint256 depth;
        while (width < listings.length) width *= 2;
        for (uint256 nodes = width; nodes > 1; nodes /= 2) ++depth;
        bytes32[] memory tree = new bytes32[](2 * width);
        for (uint256 i; i < listings.length; ++i) {
            tree[width + i] = hashes.hashListingLeaf(_listingDigest(listings[i]));
        }
        for (uint256 i = width - 1; i != 0; --i) {
            bytes32 a = tree[2 * i];
            bytes32 b = tree[2 * i + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        auth.listingRoots = new ICart.ListingRoot[](1);
        auth.listingRoots[0] = ICart.ListingRoot(tree[1], 0, block.timestamp + 1 days);
        auth.listingRootSignatures = new bytes[](1);
        auth.listingRootSignatures[0] =
            _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), auth.listingRoots[0]));
        auth.listingRootIndexes = new uint256[](listings.length);
        auth.listingProofs = new bytes32[][](listings.length);
        for (uint256 i; i < listings.length; ++i) {
            auth.listingProofs[i] = new bytes32[](depth);
            uint256 node = width + i;
            for (uint256 j; j < depth; ++j) {
                auth.listingProofs[i][j] = tree[node ^ 1];
                node /= 2;
            }
        }
    }
}
