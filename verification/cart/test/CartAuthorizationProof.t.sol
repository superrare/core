// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartAuthorizationBase} from "./CartAuthorizationBase.sol";
import {ICart} from "cart-src/ICart.sol";

/// @notice Authorization rejection and signed-envelope consistency for one purchase.
/// @dev Digest-selective ERC1271 oracles model authority, not signature cryptography. The changed
/// amount and wrong-domain tests assume distinct typed digests, expressing collision resistance.
/// Hash-mismatch claims approve an envelope containing a deliberately different payload hash.
contract CartAuthorizationProof is CartAuthorizationBase {
    function testProof_validAuthorization(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        _fund(p, baseline);
        _assertAccepted(p);
    }

    function testProof_platformRejectsUnapprovedDigest(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        seller.allow(p.rootDigest);
        // Platform oracle starts disabled: no order digest has been approved.
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidSignature.selector);
    }

    function testProof_sellerRejectsUnapprovedRoot(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        platform.allow(p.orderDigest);
        // Seller oracle starts disabled: no root digest has been approved.
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidSignature.selector);
    }

    function testProof_changedAmountRejectsOldApproval(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        p.order.paymentAmount = uint256(quantity) + 1;
        bytes32 changedDigest = hashes.hashOrder(cart.DOMAIN_SEPARATOR(), p.order);
        vm.assume(changedDigest != p.orderDigest);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidSignature.selector);
    }

    function testProof_signedLinesHashMustMatch(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        p.order.orderLinesHash = _differentHash(p.order.orderLinesHash);
        p.orderDigest = hashes.hashOrder(cart.DOMAIN_SEPARATOR(), p.order);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidOrderLinesHash.selector);
    }

    function testProof_signedRouteHashMustMatch(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        p.order.payoutRouteHash = _differentHash(p.order.payoutRouteHash);
        p.orderDigest = hashes.hashOrder(cart.DOMAIN_SEPARATOR(), p.order);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidPayoutRouteHash.selector);
    }

    function testProof_signedActionsHashMustMatch(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        p.order.fulfillmentActionsHash = _differentHash(p.order.fulfillmentActionsHash);
        p.orderDigest = hashes.hashOrder(cart.DOMAIN_SEPARATOR(), p.order);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidFulfillmentActionsHash.selector);
    }

    function testProof_cachedRootCannotAuthorizeDifferentSeller(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = p.listings[0];
        listings[1] = ICart.Listing({
            listingSalt: bytes32(uint256(2)),
            seller: address(platform),
            sku: bytes32(uint256(2)),
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            tokenContract: address(0),
            tokenId: 0,
            settlementCurrency: address(0),
            minimumUnitPrice: 1,
            availableQuantity: quantity,
            paymentRecipient: PAYEE
        });
        bytes32 secondDigest = hashes.hashListing(cart.DOMAIN_SEPARATOR(), listings[1]);
        p.listings = listings;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = p.lines[0];
        lines[1] = ICart.OrderLine({
            sku: bytes32(uint256(2)),
            listingDigest: secondDigest,
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            quantity: quantity,
            settlementCurrency: address(0),
            amount: quantity,
            paymentRecipient: PAYEE
        });
        p.lines = lines;
        // Widened addition retains the same amount without a symbolic division overflow guard.
        p.order.paymentAmount = uint256(quantity) + uint256(quantity);
        p.auth.listingRootIndexes = new uint256[](2);
        p.auth.listingRootIndexes[0] = 0;
        p.auth.listingRootIndexes[1] = 0;
        p.auth.listingProofs = new bytes32[][](2);
        p.auth.listingProofs[0] = new bytes32[](0);
        p.auth.listingProofs[1] = new bytes32[](0);
        // The first leaf is in the singleton root. The second seller must be rejected before
        // attempting its Merkle proof or signature, even though the root index is already cached.
        _refreshOrder(p);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidListingRoot.selector);
        assert(cart.filledQuantity(secondDigest) == 0);
    }

    function testProof_sellerRootRequiresMerkleMembership(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        bytes32 originalDigest = p.listingDigest;
        // Change only the listing salt and the line's corresponding digest. Seller, price,
        // quantity and payout remain valid; the previously signed singleton root stays fixed.
        p.listings[0].listingSalt = bytes32(uint256(2));
        p.listingDigest = hashes.hashListing(cart.DOMAIN_SEPARATOR(), p.listings[0]);
        p.lines[0].listingDigest = p.listingDigest;
        assert(hashes.hashListingLeaf(p.listingDigest) != p.auth.listingRoots[0].listingsRoot);
        _refreshOrder(p);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidMerkleProof.selector);
        assert(cart.filledQuantity(originalDigest) == 0);
    }

    function testProof_platformApprovalUsesCartDomain(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        bytes32 wrongDomain = _differentHash(cart.DOMAIN_SEPARATOR());
        bytes32 wrongDigest = hashes.hashOrder(wrongDomain, p.order);
        vm.assume(wrongDigest != p.orderDigest);
        platform.allow(wrongDigest);
        seller.allow(p.rootDigest);
        _fund(p, baseline);
        _assertRejected(p, ICart.InvalidSignature.selector);
    }

    function testConcreteValidAuthorization() public {
        testProof_validAuthorization(11, 7);
    }

    function testConcretePlatformRejectsUnapprovedDigest() public {
        testProof_platformRejectsUnapprovedDigest(11, 7);
    }

    function testConcreteSellerRejectsUnapprovedRoot() public {
        testProof_sellerRejectsUnapprovedRoot(11, 7);
    }

    function testConcreteChangedAmountRejectsOldApproval() public {
        testProof_changedAmountRejectsOldApproval(11, 7);
    }

    function testConcreteSignedLinesHashMustMatch() public {
        testProof_signedLinesHashMustMatch(11, 7);
    }

    function testConcreteSignedRouteHashMustMatch() public {
        testProof_signedRouteHashMustMatch(11, 7);
    }

    function testConcreteSignedActionsHashMustMatch() public {
        testProof_signedActionsHashMustMatch(11, 7);
    }

    function testConcreteCachedRootCannotAuthorizeDifferentSeller() public {
        testProof_cachedRootCannotAuthorizeDifferentSeller(11, 7);
    }

    function testConcretePlatformApprovalUsesCartDomain() public {
        testProof_platformApprovalUsesCartDomain(11, 7);
    }

    function testConcreteSellerRootRequiresMerkleMembership() public {
        testProof_sellerRootRequiresMerkleMembership(11, 7);
    }

    function _differentHash(bytes32 original) private pure returns (bytes32) {
        return original == bytes32(0) ? bytes32(uint256(1)) : bytes32(0);
    }
}
