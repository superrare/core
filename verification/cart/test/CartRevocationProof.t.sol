// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartAuthorizationBase} from "./CartAuthorizationBase.sol";
import {ICart} from "cart-src/ICart.sol";

/// @notice Fixed-history cancellation, seller isolation and deadline specifications.
/// @dev Uses the base's digest-selective ERC1271 oracles and one native OFF_CHAIN listing.
/// These claims cover one revocation operation followed by one purchase, not arbitrary histories
/// or signature cryptography. Root cancellation requires a nonzero signed root digest because
/// Cart rejects the zero sentinel. Quantities/baselines retain their uint96 domains.
contract CartRevocationProof is CartAuthorizationBase {
    address private constant OTHER = address(0x6001);

    function testRevocation_sellerListingCancellation(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        _fund(p, baseline);
        vm.prank(address(seller));
        cart.cancelListing(p.listingDigest);
        assert(cart.cancelledListings(address(seller), p.listingDigest));
        _assertRejected(p, ICart.CancelledListing.selector);
        assert(cart.cancelledListings(address(seller), p.listingDigest));
        assert(cart.listingNonces(address(seller)) == 0);
    }

    function testRevocation_sellerRootCancellation(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        vm.assume(p.rootDigest != bytes32(0));
        _authorize(p);
        _fund(p, baseline);
        vm.prank(address(seller));
        cart.cancelListingRoot(p.rootDigest);
        assert(cart.cancelledListingRoots(address(seller), p.rootDigest));
        _assertRejected(p, ICart.CancelledListingRoot.selector);
        assert(cart.cancelledListingRoots(address(seller), p.rootDigest));
        assert(cart.listingNonces(address(seller)) == 0);
    }

    function testRevocation_sellerNonceInvalidation(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        _fund(p, baseline);
        vm.prank(address(seller));
        cart.invalidateListingNonce();
        assert(cart.listingNonces(address(seller)) == 1);
        _assertRejected(p, ICart.InvalidListingNonce.selector);
        assert(cart.listingNonces(address(seller)) == 1);
        assert(!cart.cancelledListings(address(seller), p.listingDigest));
        assert(!cart.cancelledListingRoots(address(seller), p.rootDigest));
    }

    function testRevocation_otherListingCancellationIsIsolated(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        _fund(p, baseline);
        vm.prank(OTHER);
        cart.cancelListing(p.listingDigest);
        assert(cart.cancelledListings(OTHER, p.listingDigest));
        assert(!cart.cancelledListings(address(seller), p.listingDigest));
        _assertAccepted(p);
        assert(cart.cancelledListings(OTHER, p.listingDigest));
        assert(!cart.cancelledListings(address(seller), p.listingDigest));
        assert(cart.listingNonces(address(seller)) == 0);
    }

    function testRevocation_otherRootCancellationIsIsolated(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        vm.assume(p.rootDigest != bytes32(0));
        _authorize(p);
        _fund(p, baseline);
        vm.prank(OTHER);
        cart.cancelListingRoot(p.rootDigest);
        assert(cart.cancelledListingRoots(OTHER, p.rootDigest));
        assert(!cart.cancelledListingRoots(address(seller), p.rootDigest));
        _assertAccepted(p);
        assert(cart.cancelledListingRoots(OTHER, p.rootDigest));
        assert(!cart.cancelledListingRoots(address(seller), p.rootDigest));
        assert(cart.listingNonces(address(seller)) == 0);
    }

    function testRevocation_otherNonceInvalidationIsIsolated(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        _authorize(p);
        _fund(p, baseline);
        vm.prank(OTHER);
        cart.invalidateListingNonce();
        assert(cart.listingNonces(OTHER) == 1);
        assert(cart.listingNonces(address(seller)) == 0);
        _assertAccepted(p);
        assert(cart.listingNonces(OTHER) == 1);
        assert(cart.listingNonces(address(seller)) == 0);
        assert(!cart.cancelledListings(address(seller), p.listingDigest));
        assert(!cart.cancelledListingRoots(address(seller), p.rootDigest));
    }

    function testRevocation_expiredOrder(uint96 quantity, uint96 baseline) public {
        vm.assume(block.timestamp > 0);
        Purchase memory p = _purchase(quantity);
        p.order.deadline = block.timestamp - 1;
        _refreshOrder(p);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.DeadlineExpired.selector);
    }

    function testRevocation_expiredRoot(uint96 quantity, uint96 baseline) public {
        vm.assume(block.timestamp > 0);
        Purchase memory p = _purchase(quantity);
        p.auth.listingRoots[0].deadline = block.timestamp - 1;
        _refreshRoot(p);
        _authorize(p);
        _fund(p, baseline);
        _assertRejected(p, ICart.DeadlineExpired.selector);
    }

    function testRevocation_deadlinesInclusive(uint96 quantity, uint96 baseline) public {
        Purchase memory p = _purchase(quantity);
        p.order.deadline = block.timestamp;
        p.auth.listingRoots[0].deadline = block.timestamp;
        _refreshOrder(p);
        _refreshRoot(p);
        _authorize(p);
        _fund(p, baseline);
        _assertAccepted(p);
    }

    function testConcreteSellerListingCancellation() public {
        testRevocation_sellerListingCancellation(3, 7);
    }

    function testConcreteSellerRootCancellation() public {
        testRevocation_sellerRootCancellation(3, 7);
    }

    function testConcreteSellerNonceInvalidation() public {
        testRevocation_sellerNonceInvalidation(3, 7);
    }

    function testConcreteOtherListingCancellationIsIsolated() public {
        testRevocation_otherListingCancellationIsIsolated(3, 7);
    }

    function testConcreteOtherRootCancellationIsIsolated() public {
        testRevocation_otherRootCancellationIsIsolated(3, 7);
    }

    function testConcreteOtherNonceInvalidationIsIsolated() public {
        testRevocation_otherNonceInvalidationIsIsolated(3, 7);
    }

    function testConcreteExpiredOrder() public {
        testRevocation_expiredOrder(3, 7);
    }

    function testConcreteExpiredRoot() public {
        testRevocation_expiredRoot(3, 7);
    }

    function testConcreteDeadlinesInclusive() public {
        testRevocation_deadlinesInclusive(3, 7);
    }
}
