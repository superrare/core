// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartTest, CartTestToken, CartTestERC721, CartTestMintableERC721, CartTestERC1155} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartLens} from "../../cart/CartLens.sol";
import {ICartLens} from "../../cart/ICartLens.sol";

/// @dev Some ERC20s reject zero transfers; a free purchase must not call either transfer method.
contract CartZeroTransferRejectingToken is CartTestToken {
  constructor() CartTestToken("Zero rejecting token", "ZERO") {}

  function _transfer(address from, address to, uint256 amount) internal override {
    require(amount != 0, "zero transfer");
    super._transfer(from, to, amount);
  }
}

/// @dev A free seller payout must not require a payable recipient.
contract CartNonpayableSeller {}

contract CartFreeTest is CartTest {
  function testFreeErc721TransferStillMovesTheToken() public {
    CartTestERC721 token = new CartTestERC721();
    token.mint(seller, 7);
    vm.prank(seller);
    token.setApprovalForAll(address(cart), true);
    ICart.Listing memory listing = _listing(
      keccak256("free-transfer"),
      ICart.FulfillmentKind.ERC721_TRANSFER,
      address(token),
      7,
      sellerPayout
    );
    listing.minimumUnitPrice = 0;
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
    actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
    _executeNativeListing(listing, "free-transfer-order", 1, actions);
    assertEq(token.ownerOf(7), collector);
    assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
  }

  function testFreeAndPaidListingsSettleTogether() public {
    ICart.Listing[] memory listings = new ICart.Listing[](2);
    listings[0] = _listing(keccak256("mixed-free"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
    listings[0].minimumUnitPrice = 0;
    listings[1] = _listing(keccak256("mixed-paid"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
    ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
    lines[0] = _lineForListing(listings[0], 1, 0)[0];
    lines[1] = _lineForListing(listings[1], 1, 1 ether)[0];
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
    ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
    ICart.PurchaseOrder memory order = _order("mixed-free-paid", lines, routes, actions);
    ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
    bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
    vm.deal(payer, 1 ether);
    vm.prank(payer);
    cart.executePurchase{value: 1 ether}(
      order,
      lines,
      listings,
      authorization,
      _combineRoutes(routes),
      actions,
      signature
    );
    assertEq(sellerPayout.balance, 1 ether);
    assertEq(cart.filledQuantity(_listingDigest(listings[0])), 1);
    assertEq(cart.filledQuantity(_listingDigest(listings[1])), 1);
  }

  function testLargeFreeOrderPassesLensAndFillsEveryListing() public {
    uint256 count = 65;
    ICart.Listing[] memory listings = new ICart.Listing[](count);
    ICart.OrderLine[] memory lines = new ICart.OrderLine[](count);
    for (uint256 i; i < count; ++i) {
      listings[i] = _listing(
        keccak256(abi.encode("large-free", i)),
        ICart.FulfillmentKind.OFF_CHAIN,
        address(0),
        0,
        sellerPayout
      );
      listings[i].minimumUnitPrice = 0;
    }
    // Reverse line order so each lookup must resolve the signed Listing digest.
    for (uint256 i; i < count; ++i) {
      lines[i] = _lineForListing(listings[count - i - 1], 1, 0)[0];
    }
    ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
    ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
    ICart.PayoutRoute memory route = _combineRoutes(routes);
    ICart.PurchaseOrder memory order = _order("large-free-order", lines, routes, actions);
    bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
    CartLens lens = new CartLens();
    for (uint256 i; i < count; ++i) {
      ICartLens.ValidationResult memory result = lens.validateListing(
        address(cart),
        listings[i],
        authorization.listingRoots[i],
        authorization.listingRootSignatures[i],
        authorization.listingProofs[i],
        1
      );
      assertTrue(result.valid);
    }
    ICartLens.ValidationResult memory envelope =
      lens.validatePurchaseEnvelope(address(cart), order, lines, route, actions, signature);
    assertTrue(envelope.valid);
    assertEq(order.paymentAmount, 0);
    vm.deal(payer, 0);
    vm.prank(payer);
    ICart.MintResult[] memory mintResults =
      cart.executePurchase(order, lines, listings, authorization, route, actions, signature);
    assertEq(mintResults.length, 0);
    assertTrue(cart.executedOrderIds(order.orderId));
    assertEq(sellerPayout.balance, 0);
    for (uint256 i; i < count; ++i) {
      assertEq(cart.filledQuantity(_listingDigest(listings[i])), 1);
    }
  }

  function testFreeOrderStillRequiresPlatformSignature() public {
    ICart.Listing memory listing = _listing(
      keccak256("unsigned-free"),
      ICart.FulfillmentKind.OFF_CHAIN,
      address(0),
      0,
      sellerPayout
    );
    listing.minimumUnitPrice = 0;
    ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 0);
    ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
    ICart.PurchaseOrder memory order = _order("unsigned-free-order", lines, routes, actions);
    ICart.Listing[] memory listings = _singletonListing(listing);
    ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
    bytes memory signature = _sign(SELLER_PK, _orderDigest(order));
    vm.expectRevert(abi.encodeWithSelector(ICart.InvalidSignature.selector, vm.addr(PLATFORM_PK), _orderDigest(order)));
    vm.prank(payer);
    cart.executePurchase(order, lines, listings, authorization, _combineRoutes(routes), actions, signature);
    assertFalse(cart.executedOrderIds(order.orderId));
    assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
  }

  function testFreeErc721MintStillFulfillsAndConsumesInventory() public {
    CartTestMintableERC721 token = new CartTestMintableERC721();
    token.transferOwnership(seller);
    vm.prank(seller);
    token.setMinter(address(cart), true);
    ICart.Listing memory listing = _listing(
      keccak256("free-721"),
      ICart.FulfillmentKind.ERC721_MINT_TO,
      address(token),
      0,
      sellerPayout
    );
    listing.minimumUnitPrice = 0;
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
    actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

    ICart.MintResult[] memory mintResults = _executeNativeListing(listing, "free-721-order", 1, actions);

    assertEq(mintResults.length, 1);
    assertEq(mintResults[0].fulfillmentActionIndex, 0);
    assertEq(mintResults[0].tokenIds.length, 1);
    assertEq(mintResults[0].tokenIds[0], 1);
    assertEq(token.ownerOf(1), collector);
    assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
    vm.expectRevert();
    this.executeFreeListingAgain(listing, actions);
    assertEq(token.ownerOf(1), collector);
  }

  function executeFreeListingAgain(ICart.Listing memory listing, ICart.FulfillmentAction[] memory actions) external {
    _executeNativeListing(listing, "another-free-721-order", 1, actions);
  }

  function testFreeErc1155MintFulfillsEveryUnit() public {
    CartTestERC1155 token = new CartTestERC1155();
    token.transferOwnership(seller);
    vm.prank(seller);
    token.setMinter(address(cart), true);
    ICart.Listing memory listing = _listingWithQuantity(
      keccak256("free-1155"),
      ICart.FulfillmentKind.ERC1155_MINT_TO,
      address(token),
      7,
      sellerPayout,
      3
    );
    listing.minimumUnitPrice = 0;
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
    actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 3, recipient: collector});
    _executeNativeListing(listing, "free-1155-order", 3, actions);
    assertEq(token.balanceOf(collector, 7), 3);
    assertEq(cart.filledQuantity(_listingDigest(listing)), 3);
  }

  function testFreeErc20OrderSkipsZeroTransfersAndPreservesBalances() public {
    CartZeroTransferRejectingToken token = new CartZeroTransferRejectingToken();
    ICart.Listing memory listing = _listing(
      keccak256("free-erc20"),
      ICart.FulfillmentKind.NONE,
      address(0),
      0,
      address(new CartNonpayableSeller())
    );
    listing.minimumUnitPrice = 0;
    listing.settlementCurrency = address(token);
    ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 0);
    lines[0].settlementCurrency = address(token);
    ICart.PayoutRoute memory route = _combineRoutes(_emptyRoutes(1));
    ICart.PurchaseOrder memory order = _orderSingle("free-erc20-order", token, lines, route, 0);
    token.mint(address(cart), 5 ether);
    vm.deal(address(cart), 2 ether);
    weth.mint(address(cart), 3 ether);
    _execute(order, lines, listing, route);
    assertEq(token.balanceOf(address(cart)), 5 ether);
    assertEq(address(cart).balance, 2 ether);
    assertEq(weth.balanceOf(address(cart)), 3 ether);
    assertTrue(cart.executedOrderIds(order.orderId));
    vm.expectRevert(abi.encodeWithSelector(ICart.AlreadyExecuted.selector, order.orderId));
    this.executeAgain(order, lines, listing, route);
  }

  function executeAgain(
    ICart.PurchaseOrder memory order,
    ICart.OrderLine[] memory lines,
    ICart.Listing memory listing,
    ICart.PayoutRoute memory route
  ) external {
    _execute(order, lines, listing, route);
  }

  function testFreeNativeOrderSkipsNonpayableRecipientAndLensAcceptsIt() public {
    ICart.Listing memory listing = _listing(
      keccak256("free-native"),
      ICart.FulfillmentKind.NONE,
      address(0),
      0,
      address(new CartNonpayableSeller())
    );
    listing.minimumUnitPrice = 0;
    ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(_singletonListing(listing), SELLER_PK);
    ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 0);
    ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
    ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
    ICart.PurchaseOrder memory order = _order("free-native-order", lines, routes, actions);
    CartLens lens = new CartLens();
    ICartLens.ValidationResult memory result = lens.validateListing(
      address(cart),
      listing,
      authorization.listingRoots[0],
      authorization.listingRootSignatures[0],
      authorization.listingProofs[0],
      1
    );
    assertTrue(result.valid);
    result = lens.validatePurchaseEnvelope(
      address(cart),
      order,
      lines,
      _combineRoutes(routes),
      actions,
      _sign(PLATFORM_PK, _orderDigest(order))
    );
    assertTrue(result.valid);
    _executeNativeListing(listing, "free-native-order", 1, actions);
  }

  function testFreeListingKeepsFixedAndPerUnitFees() public {
    ICart.Listing memory listing = _listingWithQuantity(
      keccak256("free-with-fees"),
      ICart.FulfillmentKind.NONE,
      address(0),
      0,
      sellerPayout,
      3
    );
    listing.minimumUnitPrice = 0;
    ICart.OrderLine[] memory lines = new ICart.OrderLine[](3);
    lines[0] = _lineForListing(listing, 3, 0)[0];
    lines[1] = ICart.OrderLine(
      keccak256("fixed"),
      bytes32(0),
      ICart.FulfillmentKind.NONE,
      1,
      address(0),
      0.1 ether,
      collector
    );
    lines[2] = ICart.OrderLine(
      keccak256("per-unit"),
      bytes32(0),
      ICart.FulfillmentKind.NONE,
      3,
      address(0),
      0.6 ether,
      collector
    );
    ICart.PayoutRoute[] memory routes = _emptyRoutes(3);
    ICart.PurchaseOrder memory order = _order("free-with-fees-order", lines, routes, new ICart.FulfillmentAction[](0));
    _execute(order, lines, listing, _combineRoutes(routes));
    assertEq(collector.balance, 0.7 ether);
    assertEq(sellerPayout.balance, 0);
    assertEq(cart.filledQuantity(_listingDigest(listing)), 3);
  }

  function testZeroFundingCannotPayFeesFromPreexistingBalance() public {
    ICart.Listing memory listing = _listing(
      keccak256("unfunded-fee"),
      ICart.FulfillmentKind.NONE,
      address(0),
      0,
      sellerPayout
    );
    listing.minimumUnitPrice = 0;
    ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
    lines[0] = _lineForListing(listing, 1, 0)[0];
    lines[1] = ICart.OrderLine(
      keccak256("fee"),
      bytes32(0),
      ICart.FulfillmentKind.NONE,
      1,
      address(0),
      1 ether,
      collector
    );
    ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
    ICart.PurchaseOrder memory order = _order("unfunded-fee-order", lines, routes, new ICart.FulfillmentAction[](0));
    order.paymentAmount = 0;
    vm.deal(address(cart), 1 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        ICart.OrderLineFailed.selector,
        0,
        ICart.FailureStage.ROUTING,
        abi.encode(uint256(0), uint256(1 ether))
      )
    );
    this.executeAgain(order, lines, listing, _combineRoutes(routes));
    assertFalse(cart.executedOrderIds(order.orderId));
    assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
    assertEq(address(cart).balance, 1 ether);
  }

  function _execute(
    ICart.PurchaseOrder memory order,
    ICart.OrderLine[] memory lines,
    ICart.Listing memory listing,
    ICart.PayoutRoute memory route
  ) internal {
    ICart.Listing[] memory listings = _singletonListing(listing);
    ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
    bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
    vm.deal(payer, order.paymentAmount);
    vm.prank(payer);
    cart.executePurchase{value: order.paymentAmount}(
      order,
      lines,
      listings,
      authorization,
      route,
      new ICart.FulfillmentAction[](0),
      signature
    );
  }
}
