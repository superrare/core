// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartFixture} from "./CartFixture.sol";
import {ICart} from "../../cart/ICart.sol";

contract CartListingIndexTest is CartFixture {
    function testFuzzListingIndexWraparoundAndRepeatedLines(uint8 seed) public {
        ICart.Listing[] memory listings = collidingListings();
        uint256 repeats = uint256(seed) % 5 + 1;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](repeats + 2);
        lines[0] = _lineForListing(listings[2], 1, 1 ether)[0];
        lines[1] = _lineForListing(listings[1], 1, 1 ether)[0];
        for (uint256 i = 2; i < lines.length; ++i) lines[i] = _lineForListing(listings[0], 1, 1 ether)[0];
        this.executeCase(listings, lines);
        assertEq(cart.filledQuantity(_listingDigest(listings[0])), repeats);
        assertEq(cart.filledQuantity(_listingDigest(listings[1])), 1);
        assertEq(cart.filledQuantity(_listingDigest(listings[2])), 1);
        assertEq(sellerPayout.balance, lines.length * 1 ether);
    }
    function testListingIndexDuplicateInCollisionChain() public {
        ICart.Listing[] memory selected = collidingListings();
        ICart.Listing[] memory listings = new ICart.Listing[](4);
        for (uint256 i; i < 3; ++i) listings[i] = selected[i];
        listings[3] = selected[1];
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](4);
        for (uint256 i; i < 4; ++i) lines[i] = _lineForListing(listings[i], 1, 1 ether)[0];
        vm.expectRevert(abi.encodeWithSelector(ICart.DuplicateListingDigest.selector, _listingDigest(selected[1])));
        this.executeCase(listings, lines);
        assertEq(cart.filledQuantity(_listingDigest(selected[0])), 0);
    }
    function testListingIndexMissingAfterCollisionChain() public {
        ICart.Listing[] memory listings = collidingListings();
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](3);
        for (uint256 i; i < 3; ++i) lines[i] = _lineForListing(listings[i], 1, 1 ether)[0];
        lines[2].listingDigest = bytes32(uint256(7));
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingNotFound.selector, bytes32(uint256(7))));
        this.executeCase(listings, lines);
    }
    function testListingIndexRejectsUnusedListing() public {
        ICart.Listing[] memory listings = collidingListings();
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listings[2], 1, 1 ether)[0];
        lines[1] = _lineForListing(listings[0], 1, 1 ether)[0];
        // Shape validation permits no more listings than lines; add a repeated reference.
        ICart.OrderLine[] memory supplied = new ICart.OrderLine[](3);
        supplied[0] = lines[0]; supplied[1] = lines[1]; supplied[2] = lines[1];
        vm.expectRevert(abi.encodeWithSelector(ICart.ExtraListing.selector, 1));
        this.executeCase(listings, supplied);
    }
    function testListingIndexSingleMissingDigest() public {
        ICart.Listing[] memory listings = new ICart.Listing[](1);
        listings[0] = _listing(keccak256("single"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listings[0], 1, 1 ether);
        lines[0].listingDigest = bytes32(uint256(7));
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingNotFound.selector, bytes32(uint256(7))));
        this.executeCase(listings, lines);
    }
    function testListingIndexNoListingsMissingDigest() public {
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine(keccak256("missing"), bytes32(uint256(7)), ICart.FulfillmentKind.OFF_CHAIN, 1, address(0), 1 ether, sellerPayout);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingNotFound.selector, bytes32(uint256(7))));
        this.executeCase(listings, lines);
    }
    function collidingListings() internal view returns (ICart.Listing[] memory listings) {
        listings = new ICart.Listing[](3);
        uint256 found;
        for (uint256 salt; found < 3; ++salt) {
            ICart.Listing memory listing = _listingWithQuantity(keccak256(abi.encode("collision", salt)), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout, 10);
            // Three entries use an eight-slot table: collide at the last slot to exercise wraparound.
            bytes32 digest = _listingDigest(listing);
            if ((uint256(digest) & 7) == 7 && digest != bytes32(uint256(7))) listings[found++] = listing;
        }
    }
    function executeCase(ICart.Listing[] memory listings, ICart.OrderLine[] memory lines) external {
        require(msg.sender == address(this));
        ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("listing-index", lines, route, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, order.paymentAmount);
        vm.prank(payer);
        cart.executePurchase{value: order.paymentAmount}(order, lines, listings, auth, route, actions, signature);
    }
}
