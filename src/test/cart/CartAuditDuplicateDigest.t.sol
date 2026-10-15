// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartTest} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";

/// @notice Duplicate identity is now defined by the complete Listing digest.
contract CartAuditDuplicateDigestTest is CartTest {
    function testDuplicateListingDigestIsRejected() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("duplicate-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 1
        );
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listing;
        listings[1] = listing;

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listing, 1, 1 ether)[0];
        lines[1] = lines[0];
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("duplicate-listing-order", lines, routes, actions);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.DuplicateListingDigest.selector, _listingDigest(listing)));
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }
}
