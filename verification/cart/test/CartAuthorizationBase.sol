// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartProofBase} from "./CartProofBase.sol";
import {Cart} from "cart-src/Cart.sol";
import {ICart} from "cart-src/ICart.sol";

/// @dev A fixture-controlled authorization oracle, not an implementation of signature cryptography.
/// Only the explicitly approved digest returns ERC1271 magic. Test code controls the oracle.
contract CartDigestSigner {
    bytes32 public approvedDigest;
    bool public enabled;

    function allow(bytes32 digest) external {
        approvedDigest = digest;
        enabled = true;
    }

    function deny() external {
        enabled = false;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return enabled && digest == approvedDigest ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev One native, unit-price OFF_CHAIN listing, singleton Merkle root and no fulfillment calls.
/// Cart and hashing execute normally; platform/seller authority is a digest-selective ERC1271 oracle.
abstract contract CartAuthorizationBase is CartProofBase {
    CartDigestSigner internal platform;
    CartDigestSigner internal seller;

    struct Purchase {
        ICart.PurchaseOrder order;
        ICart.OrderLine[] lines;
        ICart.Listing[] listings;
        ICart.ListingPurchaseAuthorization auth;
        ICart.PayoutRoute route;
        ICart.FulfillmentAction[] actions;
        bytes32 listingDigest;
        bytes32 rootDigest;
        bytes32 orderDigest;
    }

    function setUp() public virtual override {
        super.setUp();
        platform = new CartDigestSigner();
        seller = new CartDigestSigner();
        cart.setPlatformSigner(address(platform));
    }

    function _purchase(uint96 quantity) internal view returns (Purchase memory p) {
        vm.assume(quantity > 0);
        p.listings = new ICart.Listing[](1);
        p.listings[0] = ICart.Listing({
            listingSalt: bytes32(uint256(1)),
            seller: address(seller),
            sku: bytes32(uint256(1)),
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            tokenContract: address(0),
            tokenId: 0,
            settlementCurrency: address(0),
            minimumUnitPrice: 1,
            availableQuantity: quantity,
            paymentRecipient: PAYEE
        });
        p.listingDigest = hashes.hashListing(cart.DOMAIN_SEPARATOR(), p.listings[0]);
        p.auth.listingRoots = new ICart.ListingRoot[](1);
        p.auth.listingRoots[0] = ICart.ListingRoot({
            listingsRoot: hashes.hashListingLeaf(p.listingDigest), nonce: 0, deadline: block.timestamp + 1 days
        });
        vm.assume(p.listingDigest != bytes32(0));
        vm.assume(p.auth.listingRoots[0].listingsRoot != bytes32(0));
        p.auth.listingRootSignatures = new bytes[](1);
        p.auth.listingRootIndexes = new uint256[](1);
        p.auth.listingRootIndexes[0] = 0;
        p.auth.listingProofs = new bytes32[][](1);
        p.auth.listingProofs[0] = new bytes32[](0);
        p.lines = new ICart.OrderLine[](1);
        p.lines[0] = ICart.OrderLine({
            sku: bytes32(uint256(1)),
            listingDigest: p.listingDigest,
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            quantity: quantity,
            settlementCurrency: address(0),
            amount: quantity,
            paymentRecipient: PAYEE
        });
        p.actions = new ICart.FulfillmentAction[](0);
        p.order = ICart.PurchaseOrder({
            orderId: bytes32(uint256(1)),
            paymentCurrency: address(0),
            paymentAmount: quantity,
            spreadRecipient: address(this),
            deadline: block.timestamp + 1 days,
            orderLinesHash: bytes32(0),
            payoutRouteHash: bytes32(0),
            fulfillmentActionsHash: bytes32(0)
        });
        _refreshOrder(p);
        _refreshRoot(p);
    }

    function _refreshOrder(Purchase memory p) internal view {
        p.order.orderLinesHash = hashes.hashOrderLines(p.lines);
        p.order.payoutRouteHash = hashes.hashPayoutRoute(p.route);
        p.order.fulfillmentActionsHash = hashes.hashFulfillmentActions(p.actions);
        p.orderDigest = hashes.hashOrder(cart.DOMAIN_SEPARATOR(), p.order);
    }

    function _refreshRoot(Purchase memory p) internal view {
        p.rootDigest = hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), p.auth.listingRoots[0]);
    }

    function _authorize(Purchase memory p) internal {
        platform.allow(p.orderDigest);
        seller.allow(p.rootDigest);
    }

    function _fund(Purchase memory p, uint96 baseline) internal {
        vm.deal(address(this), p.order.paymentAmount);
        vm.deal(address(cart), baseline);
        vm.deal(PAYEE, 0);
    }

    function _callPurchase(Purchase memory p) internal returns (bool, bytes memory) {
        return address(cart).call{value: p.order.paymentAmount}(
            abi.encodeCall(Cart.executePurchase, (p.order, p.lines, p.listings, p.auth, p.route, p.actions, bytes("")))
        );
    }

    function _assertRejected(Purchase memory p, bytes4 expectedError) internal {
        uint256 buyerBefore = address(this).balance;
        uint256 cartBefore = address(cart).balance;
        uint256 payeeBefore = PAYEE.balance;
        (bool success, bytes memory reason) = _callPurchase(p);
        assert(!success);
        assert(reason.length >= 4 && bytes4(reason) == expectedError);
        assert(!cart.executedOrderIds(p.order.orderId));
        assert(cart.filledQuantity(p.listingDigest) == 0);
        assert(address(this).balance == buyerBefore);
        assert(address(cart).balance == cartBefore);
        assert(PAYEE.balance == payeeBefore);
    }

    function _assertAccepted(Purchase memory p) internal {
        uint256 cartBefore = address(cart).balance;
        (bool success,) = _callPurchase(p);
        assert(success);
        assert(cart.executedOrderIds(p.order.orderId));
        assert(cart.filledQuantity(p.listingDigest) == p.lines[0].quantity);
        assert(PAYEE.balance == p.lines[0].amount);
        assert(address(cart).balance == cartBefore);
        assert(address(this).balance == 0);
    }
}
