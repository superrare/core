// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartTest, CartTestERC721, CartTestToken} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";

/// @notice Focused coverage for seller root-authorized Listings.
contract CartMerkleTest is CartTest {
    function testSingletonListingRootUsesEmptyProof() public {
        ICart.Listing memory listing =
            _listing(keccak256("root-singleton"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.ListingRoot memory root = ICart.ListingRoot({
            listingsRoot: hashes.hashListingLeaf(_listingDigest(listing)), nonce: 0, deadline: block.timestamp + 1 days
        });

        ICart.ListingPurchaseAuthorization memory authorization = _listingAuthorization(root);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _emptyActions();
        ICart.PurchaseOrder memory order = _order("root-singleton-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, _singletonListing(listing), authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
    }

    function testBatchListingRootKeepsRemainingLeavesAvailable() public {
        ICart.Listing memory first =
            _listing(keccak256("root-batch-first"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory second =
            _listing(keccak256("root-batch-second"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        bytes32 firstLeaf = hashes.hashListingLeaf(_listingDigest(first));
        bytes32 secondLeaf = hashes.hashListingLeaf(_listingDigest(second));
        bytes32 rootHash = _hashPair(firstLeaf, secondLeaf);
        ICart.ListingRoot memory root =
            ICart.ListingRoot({listingsRoot: rootHash, nonce: 0, deadline: block.timestamp + 1 days});

        ICart.ListingPurchaseAuthorization memory authorization = _listingAuthorization(root);
        authorization.listingRootIndexes = new uint256[](2);
        authorization.listingProofs = new bytes32[][](2);
        authorization.listingProofs[0] = new bytes32[](1);
        authorization.listingProofs[1] = new bytes32[](1);
        authorization.listingProofs[0][0] = secondLeaf;
        authorization.listingProofs[1][0] = firstLeaf;

        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = first;
        listings[1] = second;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(first, 1, 1 ether)[0];
        lines[1] = _lineForListing(second, 1, 1 ether)[0];
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = _emptyActions();
        ICart.PurchaseOrder memory order = _order("root-batch-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(first)), 1);
        assertEq(cart.filledQuantity(_listingDigest(second)), 1);
        assertFalse(cart.cancelledListingRoots(seller, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root)));
    }

    function testWholeListingRootCancellationBlocksEveryLeaf() public {
        ICart.Listing memory listing =
            _listing(keccak256("root-cancel"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.ListingRoot memory root = _singletonRoot(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _listingAuthorization(root);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _emptyActions();
        ICart.PurchaseOrder memory order = _order("root-cancel-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        bytes32 rootDigest = hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root);
        vm.prank(seller);
        cart.cancelListingRoot(rootDigest);
        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.CancelledListingRoot.selector, rootDigest));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, _singletonListing(listing), authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testExactListingCancellationBlocksListingAcrossRoots() public {
        ICart.Listing memory listing =
            _listing(keccak256("exact-listing-cancel"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.ListingRoot memory replacementRoot = _singletonRoot(listing);
        replacementRoot.deadline += 1 days;
        ICart.ListingPurchaseAuthorization memory authorization = _listingAuthorization(replacementRoot);
        bytes32 listingDigest = _listingDigest(listing);

        vm.prank(seller);
        cart.cancelListing(listingDigest);
        assertTrue(cart.cancelledListings(seller, listingDigest));

        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _emptyActions();
        ICart.PurchaseOrder memory order = _order("exact-listing-cancel-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.expectRevert(abi.encodeWithSelector(ICart.CancelledListing.selector, listingDigest));
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, _singletonListing(listing), authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testReturnedErc721CanBeRelistedWithFreshListingSalt() public {
        CartTestERC721 token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listing(
            keccak256("returned-erc721"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.ListingPurchaseAuthorization memory authorization = _listingAuthorization(_singletonRoot(listing));
        ICart.PurchaseOrder memory order = _order("returned-erc721-first-sale", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, _singletonListing(listing), authorization, _combineRoutes(routes), actions, platformSignature
        );
        assertEq(token.ownerOf(1), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);

        vm.prank(collector);
        token.setApprovalForAll(address(cart), true);
        vm.prank(collector);
        token.safeTransferFrom(collector, seller, 1);
        assertEq(token.ownerOf(1), seller);

        ICart.Listing memory relisted = listing;
        relisted.listingSalt = keccak256("returned-erc721-relisted");
        ICart.OrderLine[] memory relistedLines = _lineForListing(relisted, 1, 1 ether);
        ICart.FulfillmentAction[] memory relistedActions = new ICart.FulfillmentAction[](1);
        relistedActions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.ListingPurchaseAuthorization memory relistedAuthorization =
            _listingAuthorization(_singletonRoot(relisted));
        ICart.PurchaseOrder memory relistedOrder =
            _order("returned-erc721-second-sale", relistedLines, routes, relistedActions);
        bytes memory relistedPlatformSignature = _sign(PLATFORM_PK, _orderDigest(relistedOrder));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            relistedOrder,
            relistedLines,
            _singletonListing(relisted),
            relistedAuthorization,
            _combineRoutes(routes),
            relistedActions,
            relistedPlatformSignature
        );

        assertEq(token.ownerOf(1), collector);
        assertEq(cart.filledQuantity(_listingDigest(relisted)), 1);
    }

    function _singletonRoot(ICart.Listing memory listing) internal view returns (ICart.ListingRoot memory) {
        return ICart.ListingRoot({
            listingsRoot: hashes.hashListingLeaf(_listingDigest(listing)), nonce: 0, deadline: block.timestamp + 1 days
        });
    }

    function _listingAuthorization(ICart.ListingRoot memory root)
        internal
        returns (ICart.ListingPurchaseAuthorization memory authorization)
    {
        authorization.listingRoots = new ICart.ListingRoot[](1);
        authorization.listingRoots[0] = root;
        authorization.listingRootSignatures = new bytes[](1);
        authorization.listingRootSignatures[0] = _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root));
        authorization.listingRootIndexes = new uint256[](1);
        authorization.listingProofs = new bytes32[][](1);
        authorization.listingProofs[0] = new bytes32[](0);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _emptyActions() internal pure returns (ICart.FulfillmentAction[] memory actions) {
        actions = new ICart.FulfillmentAction[](0);
    }

    function _orderToken(
        string memory id,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute[] memory routes,
        ICart.FulfillmentAction[] memory actions,
        address paymentCurrency
    ) internal view returns (ICart.PurchaseOrder memory order) {
        order = _order(id, lines, routes, actions);
        order.paymentCurrency = paymentCurrency;
        order.orderLinesHash = hashes.hashOrderLines(lines);
    }
}
