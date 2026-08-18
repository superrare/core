// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1271} from "openzeppelin-contracts/interfaces/IERC1271.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

import {ICart} from "../../cart/ICart.sol";
import {
    CartTest,
    CartTestERC1155,
    CartTestMintableERC721,
    CartTestRevertingTransferToken,
    CartTestToken
} from "./Cart.t.sol";

contract CartTest1271Signer is IERC1271 {
    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view override returns (bytes4) {
        return ECDSA.recover(digest, signature) == signer ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

/// @notice Regression and contract-boundary coverage for Cart's signed, atomic purchase lifecycle.
contract CartVerificationTest is CartTest {
    struct NativePurchase {
        ICart.PurchaseOrder order;
        ICart.OrderLine[] lines;
        ICart.Listing[] listings;
        ICart.ListingPurchaseAuthorization authorization;
        ICart.PayoutRoute[] routes;
        ICart.FulfillmentAction[] actions;
        bytes platformSignature;
        uint256 amount;
    }

    function testExecutedOrderCannotReplay() public {
        ICart.Listing memory listing =
            _listing(keccak256("replay-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "replay-order", 1, _noActions());

        _executeNative(purchase);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(abi.encodeWithSelector(ICart.AlreadyExecuted.selector, purchase.order.orderId));
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(sellerPayout.balance, purchase.amount);
        // The replay attempt was funded again immediately before reverting.
        assertEq(payer.balance, purchase.amount);
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
    }

    function testMultiLinePurchaseConservesNativeBalances() public {
        ICart.Listing memory first = _listingWithQuantity(
            keccak256("accounting-first"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.Listing memory second = _listingWithQuantity(
            keccak256("accounting-second"), ICart.FulfillmentKind.NONE, address(0), 0, collector, 0
        );

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine({
            sku: first.sku,
            listingHash: _listingDigest(first),
            fulfillmentKind: first.fulfillmentKind,
            quantity: 2,
            settlementCurrency: address(0),
            amount: 2 ether,
            paymentRecipient: sellerPayout
        });
        lines[1] = ICart.OrderLine({
            sku: second.sku,
            listingHash: _listingDigest(second),
            fulfillmentKind: second.fulfillmentKind,
            quantity: 3,
            settlementCurrency: address(0),
            amount: 3 ether,
            paymentRecipient: collector
        });

        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = first;
        listings[1] = second;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = new ICart.PayoutRoute[](2);
        routes[0] = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0)});
        routes[1] = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0)});
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("multi-line-accounting", lines, routes, actions);
        uint256 fixedQuote = 6 ether;
        order.paymentAmount = fixedQuote;
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        uint256 sellerBefore = sellerPayout.balance;
        uint256 collectorBefore = collector.balance;
        uint256 protocolBefore = address(this).balance;
        vm.deal(payer, fixedQuote);

        vm.prank(payer);
        cart.executePurchase{value: fixedQuote}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(payer.balance, 0);
        assertEq(address(this).balance, protocolBefore + 1 ether);
        assertEq(sellerPayout.balance, sellerBefore + 2 ether);
        assertEq(collector.balance, collectorBefore + 3 ether);
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(first)), 2);
        assertEq(cart.filledQuantity(_listingDigest(second)), 3);
    }

    function testSameSettlementCurrencyGroupsExactOutputRoutesAndPermitApproval() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory first) =
            _routedTokensAndListing("grouped-route-first");
        ICart.Listing memory second =
            _listing(keccak256("grouped-route-second"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        second.settlementCurrency = address(outputToken);

        router.configureSettlement(
            address(permit2), address(0x6001), address(inputToken), address(outputToken), 2 ether, 2 ether
        );
        outputToken.mint(address(router), 2 ether);

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(first, 1, 1 ether)[0];
        lines[1] = _lineForListing(second, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(outputToken);
        lines[1].settlementCurrency = address(outputToken);

        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = first;
        listings[1] = second;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = new ICart.PayoutRoute[](2);
        for (uint256 i = 0; i < routes.length; ++i) {
            address[] memory path = new address[](2);
            path[0] = address(inputToken);
            path[1] = address(outputToken);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
            routes[i] = ICart.PayoutRoute({commands: hex"09", inputs: inputs});
        }
        ICart.PurchaseOrder memory order = _order("grouped-route", lines, routes, _noActions());
        order.paymentCurrency = address(inputToken);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 2 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 2 ether);
        uint256 firstBefore = outputToken.balanceOf(sellerPayout);
        uint256 secondBefore = outputToken.balanceOf(collector);

        vm.prank(payer);
        cart.executePurchase(
            order, lines, listings, authorization, _combineRoutes(routes), _noActions(), platformSignature
        );

        assertEq(router.executeCalls(), 1);
        assertEq(outputToken.balanceOf(sellerPayout), firstBefore + 1 ether);
        assertEq(outputToken.balanceOf(collector), secondBefore + 1 ether);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
    }

    function testSameListingAcrossLinesAggregatesCapacityAndRollsBackFailedOrder() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("accounting-aggregate"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 3
        );

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingHash: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        lines[1] = lines[0];
        ICart.Listing[] memory listings = new ICart.Listing[](1);
        listings[0] = listing;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = new ICart.PayoutRoute[](2);
        routes[0] = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0)});
        routes[1] = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0)});
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory firstOrder = _order("accounting-aggregate-first", lines, routes, actions);
        bytes memory firstPlatformSignature = _sign(PLATFORM_PK, _orderDigest(firstOrder));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            firstOrder, lines, listings, authorization, _combineRoutes(routes), actions, firstPlatformSignature
        );
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);

        ICart.OrderLine[] memory overfillLines = new ICart.OrderLine[](1);
        overfillLines[0] = _lineForListing(listing, 2, 2 ether)[0];
        ICart.PayoutRoute[] memory overfillRoutes = _emptyRoutes(1);
        ICart.PurchaseOrder memory overfillOrder =
            _order("accounting-aggregate-overfill", overfillLines, overfillRoutes, actions);
        bytes memory overfillPlatformSignature = _sign(PLATFORM_PK, _orderDigest(overfillOrder));

        vm.deal(payer, 2 ether);
        uint256 sourceBefore = payer.balance;
        uint256 payoutBefore = sellerPayout.balance;
        uint256 filledBefore = cart.filledQuantity(_listingDigest(listing));
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingQuantityExceeded.selector, _listingDigest(listing), 1, 2));
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            overfillOrder,
            overfillLines,
            listings,
            authorization,
            _combineRoutes(overfillRoutes),
            actions,
            overfillPlatformSignature
        );

        assertEq(payer.balance, sourceBefore);
        assertEq(sellerPayout.balance, payoutBefore);
        assertEq(cart.filledQuantity(_listingDigest(listing)), filledBefore);
        assertFalse(cart.executedOrderIds(overfillOrder.orderId));
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
    }

    function testSameListingAcrossLinesCannotExceedCapacityInOneOrder() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("accounting-aggregate-single-order"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 3
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listing, 2, 2 ether)[0];
        lines[1] = _lineForListing(listing, 2, 2 ether)[0];
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("accounting-aggregate-single-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 4 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingQuantityExceeded.selector, _listingDigest(listing), 3, 4));
        vm.prank(payer);
        cart.executePurchase{value: 4 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testExtraListingIsRejectedAfterResolution() public {
        ICart.Listing memory referenced = _listingWithQuantity(
            keccak256("referenced-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.Listing memory extra = _listingWithQuantity(
            keccak256("extra-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(referenced, 1, 1 ether)[0];
        lines[1] = lines[0];
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = referenced;
        listings[1] = extra;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("extra-listing", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.ExtraListing.selector, 1));
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testDuplicateListingDigestIsRejected() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("duplicate-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listing, 1, 1 ether)[0];
        lines[1] = lines[0];
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listing;
        listings[1] = listing;
        bytes32 digest = _listingDigest(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("duplicate-listing", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.DuplicateListingHash.selector, digest));
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testUnknownListingDigestIsRejected() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("known-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        bytes32 unknownDigest = keccak256("unknown-listing-digest");
        lines[0].listingHash = unknownDigest;
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("unknown-listing", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingNotFound.selector, unknownDigest));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testListingRootSignatureArrayLengthMustMatchListings() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("signature-length"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        authorization.listingRootSignatures = new bytes[](0);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("signature-length", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidArrayLength.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testListingRootsCannotExceedListings() public {
        ICart.Listing memory listing =
            _listing(keccak256("root-count-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.ListingRoot memory root = authorization.listingRoots[0];

        authorization.listingRoots = new ICart.ListingRoot[](2);
        authorization.listingRoots[0] = root;
        authorization.listingRoots[1] = root;
        authorization.listingRootSignatures = new bytes[](2);
        authorization.listingRootSignatures[0] = _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root));
        authorization.listingRootSignatures[1] = authorization.listingRootSignatures[0];

        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("root-count-bound", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidArrayLength.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testFulfillmentActionArrayIsBoundedBeforeHashing() public {
        ICart.Listing memory listing =
            _listing(keccak256("action-count-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](21);
        for (uint256 i = 0; i < actions.length; ++i) {
            actions[i] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        }
        ICart.PurchaseOrder memory order = _order("action-count-bound", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidArrayLength.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testMerkleProofDepthIsBoundedBeforeVerification() public {
        ICart.Listing memory listing =
            _listing(keccak256("proof-depth-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        authorization.listingProofs[0] = new bytes32[](65);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("proof-depth-bound", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.MerkleProofTooDeep.selector, 0, 65));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testRouteCommandCountIsBoundedBeforeHashing() public {
        ICart.Listing memory listing =
            _listing(keccak256("route-command-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        routes[0].commands = new bytes(33);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("route-command-bound", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.RouteTooManyCommands.selector, 33));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testRouteInputCountIsBoundedBeforeHashing() public {
        ICart.Listing memory listing =
            _listing(keccak256("route-input-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        routes[0].inputs = new bytes[](33);
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("route-input-bound", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.RouteTooManyInputs.selector, 33));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testSettlementFailureRestoresAccountingAndPermitAllowances() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("accounting-failed-route");
        router.configureSettlement(
            address(permit2), address(0x6002), address(inputToken), address(outputToken), 1 ether, 1 ether
        );
        outputToken.mint(address(router), 1 ether);

        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute[] memory routes = new ICart.PayoutRoute[](1);
        address[] memory path = new address[](2);
        path[0] = address(inputToken);
        path[1] = address(outputToken);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        routes[0] = ICart.PayoutRoute({commands: hex"09", inputs: inputs});
        ICart.FulfillmentAction[] memory actions = _noActions();
        ICart.PurchaseOrder memory order = _order("accounting-failed-route", lines, routes, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory settlementListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory settlementAuthorization =
            _rootAuthorization(settlementListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        uint256 sourceBefore = inputToken.balanceOf(payer);
        uint256 filledBefore = cart.filledQuantity(_listingDigest(listing));

        // The router's output is deliberately different from the signed output amount.
        router.configureSettlement(
            address(permit2), address(0x6002), address(inputToken), address(outputToken), 1 ether, 2 ether
        );
        vm.expectRevert();
        vm.prank(payer);
        cart.executePurchase(
            order,
            lines,
            settlementListings,
            settlementAuthorization,
            _combineRoutes(routes),
            actions,
            platformSignature
        );

        assertEq(inputToken.balanceOf(payer), sourceBefore);
        assertEq(inputToken.balanceOf(address(cart)), 0);
        assertEq(outputToken.balanceOf(address(cart)), 0);
        assertEq(outputToken.balanceOf(address(router)), 1 ether);
        assertEq(cart.filledQuantity(_listingDigest(listing)), filledBefore);
        assertFalse(cart.executedOrderIds(order.orderId));
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
    }

    function testFuzzNativePurchasePreservesPreexistingWethAndCapturesSpread(
        uint96 rawBaseline,
        uint8 rawQuantity,
        uint96 rawSurplus
    ) public {
        uint256 baseline = bound(uint256(rawBaseline), 0, 100 ether);
        uint256 quantity = bound(uint256(rawQuantity), 1, 20);
        uint256 surplus = bound(uint256(rawSurplus), 0, 100 ether);
        weth.mint(address(cart), baseline);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("fuzz-balance-isolation"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, quantity
        );
        NativePurchase memory purchase =
            _nativePurchase(listing, "fuzz-balance-isolation-order", quantity, _noActions());
        uint256 fixedQuote = purchase.amount + surplus;
        purchase.order.paymentAmount = fixedQuote;
        purchase.platformSignature = _sign(PLATFORM_PK, _orderDigest(purchase.order));
        vm.deal(payer, fixedQuote);
        uint256 protocolBefore = address(this).balance;

        vm.prank(payer);
        cart.executePurchase{value: fixedQuote}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertEq(weth.balanceOf(address(cart)), baseline);
        assertEq(payer.balance, 0);
        assertEq(address(this).balance, protocolBefore + surplus);
        assertEq(sellerPayout.balance, purchase.amount);
        assertEq(cart.filledQuantity(_listingDigest(listing)), quantity);
    }

    function testCancelledListingRootCannotExecute() public {
        ICart.Listing memory listing =
            _listing(keccak256("cancelled-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "cancelled-order", 1, _noActions());

        bytes32 rootDigest = hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), purchase.authorization.listingRoots[0]);
        vm.prank(seller);
        cart.cancelListingRoot(rootDigest);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(abi.encodeWithSelector(ICart.CancelledListingRoot.selector, rootDigest));
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertFalse(cart.executedOrderIds(purchase.order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
    }

    function testPauseBlocksPurchasesButNotSellerInvalidation() public {
        ICart.Listing memory listing =
            _listing(keccak256("paused-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "paused-order", 1, _noActions());
        cart.setPaused(true);

        bytes32 rootDigest = hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), purchase.authorization.listingRoots[0]);
        vm.prank(seller);
        cart.cancelListingRoot(rootDigest);
        vm.prank(seller);
        cart.invalidateListingNonce();

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.ContractPaused.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertTrue(cart.cancelledListingRoots(seller, rootDigest));
        assertEq(cart.listingNonces(seller), 1);
        assertFalse(cart.executedOrderIds(purchase.order.orderId));
    }

    function testMutatedOrderLineIsRejectedBeforeFunding() public {
        ICart.Listing memory listing =
            _listing(keccak256("mutated-line"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "mutated-line-order", 1, _noActions());
        purchase.lines[0].amount += 1;

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.InvalidOrderLinesHash.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertEq(payer.balance, purchase.amount);
        assertFalse(cart.executedOrderIds(purchase.order.orderId));
    }

    function testMutatedPayoutRouteIsRejectedBeforeFunding() public {
        ICart.Listing memory listing =
            _listing(keccak256("mutated-route"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "mutated-route-order", 1, _noActions());
        purchase.routes[0].commands = hex"08";

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.InvalidPayoutRouteHash.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testMutatedFulfillmentActionsAreRejectedBeforeFunding() public {
        ICart.Listing memory listing =
            _listing(keccak256("mutated-actions"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "mutated-actions-order", 1, _noActions());
        purchase.actions = new ICart.FulfillmentAction[](1);
        purchase.actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.InvalidFulfillmentActionsHash.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testWrongPlatformSignatureIsRejected() public {
        ICart.Listing memory listing =
            _listing(keccak256("wrong-platform-signature"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "wrong-platform-signature-order", 1, _noActions());
        purchase.platformSignature = _sign(SELLER_PK, _orderDigest(purchase.order));

        vm.deal(payer, purchase.amount);
        vm.expectRevert(
            abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(purchase.order))
        );
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testWrongSellerSignatureIsRejected() public {
        ICart.Listing memory listing =
            _listing(keccak256("wrong-seller-signature"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "wrong-seller-signature-order", 1, _noActions());
        purchase.authorization.listingRootSignatures[0] =
            _sign(PLATFORM_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), purchase.authorization.listingRoots[0]));

        vm.deal(payer, purchase.amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.InvalidSignature.selector,
                seller,
                hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), purchase.authorization.listingRoots[0])
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testErc1271PlatformAndSellerSignaturesExecute() public {
        CartTest1271Signer contractSigner = new CartTest1271Signer(platformSigner);
        cart.setPlatformSigner(address(contractSigner));

        ICart.Listing memory listing =
            _listing(keccak256("erc1271-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.seller = address(contractSigner);
        NativePurchase memory purchase = _nativePurchaseWithKeys(listing, "erc1271-order", 1, PLATFORM_PK, PLATFORM_PK);

        _executeNative(purchase);

        assertTrue(cart.executedOrderIds(purchase.order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
    }

    function testFiniteListingCannotOverfillAcrossOrders() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("finite-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 3
        );
        NativePurchase memory first = _nativePurchase(listing, "finite-order-one", 2, _noActions());
        NativePurchase memory second = _nativePurchase(listing, "finite-order-two", 2, _noActions());

        _executeNative(first);

        vm.deal(payer, second.amount);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingQuantityExceeded.selector, _listingDigest(listing), 1, 2));
        vm.prank(payer);
        cart.executePurchase{value: second.amount}(
            second.order,
            second.lines,
            second.listings,
            second.authorization,
            _combineRoutes(second.routes),
            second.actions,
            second.platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertFalse(cart.executedOrderIds(second.order.orderId));
    }

    function testOnchainActionQuantityMustEqualLineQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 2);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("action-quantity"), ICart.FulfillmentKind.ERC1155_TRANSFER, address(token), 42, sellerPayout, 2
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        NativePurchase memory purchase = _nativePurchase(listing, "action-quantity-order", 2, actions);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidFulfillmentAction.selector, 0));
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testErc721MintQuantityCannotExceedOperationLimit() public {
        CartTestMintableERC721 token = new CartTestMintableERC721();
        token.transferOwnership(seller);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("operation-limit"), ICart.FulfillmentKind.ERC721_MINT_TO, address(token), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 21, recipient: collector});
        NativePurchase memory purchase = _nativePurchase(listing, "operation-limit-order", 21, actions);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.MaxFulfillmentOperationsExceeded.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
    }

    function testPlatformSignerRotationInvalidatesOutstandingOrders() public {
        uint256 newSignerPk = 0xD00D;
        address newSigner = vm.addr(newSignerPk);
        ICart.Listing memory listing =
            _listing(keccak256("signer-rotation"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "signer-rotation-order", 1, _noActions());
        cart.setPlatformSigner(newSigner);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(
            abi.encodeWithSelector(ICart.InvalidSignature.selector, newSigner, _orderDigest(purchase.order))
        );
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );

        purchase.platformSignature = _sign(newSignerPk, _orderDigest(purchase.order));
        _executeNative(purchase);
        assertTrue(cart.executedOrderIds(purchase.order.orderId));
    }

    function testNativeFundingMustEqualSignedPaymentAmount() public {
        ICart.Listing memory listing =
            _listing(keccak256("native-value"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "native-value-order", 1, _noActions());

        vm.deal(payer, purchase.amount);
        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount - 1}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testExpiredPurchaseOrderIsRejected() public {
        ICart.Listing memory listing =
            _listing(keccak256("expired-order"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "expired-order-id", 1, _noActions());
        vm.warp(purchase.order.deadline + 1);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(
            abi.encodeWithSelector(ICart.DeadlineExpired.selector, purchase.order.deadline, block.timestamp)
        );
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function testExpiredListingIsRejected() public {
        ICart.Listing memory listing =
            _listing(keccak256("expired-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        NativePurchase memory purchase = _nativePurchase(listing, "expired-listing-order", 1, _noActions());
        purchase.authorization.listingRoots[0].deadline = block.timestamp + 1;
        uint256 rootDeadline = purchase.authorization.listingRoots[0].deadline;
        purchase.authorization.listingRootSignatures[0] =
            _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), purchase.authorization.listingRoots[0]));
        vm.warp(rootDeadline + 1);

        vm.deal(payer, purchase.amount);
        vm.expectRevert(abi.encodeWithSelector(ICart.DeadlineExpired.selector, rootDeadline, block.timestamp));
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function _nativePurchase(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        ICart.FulfillmentAction[] memory actions
    ) internal returns (NativePurchase memory) {
        return _nativePurchaseWithKeys(listing, orderId, quantity, SELLER_PK, PLATFORM_PK, actions);
    }

    function _nativePurchaseWithKeys(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        uint256 sellerPk,
        uint256 platformPk
    ) internal returns (NativePurchase memory) {
        return _nativePurchaseWithKeys(listing, orderId, quantity, sellerPk, platformPk, _noActions());
    }

    function _nativePurchaseWithKeys(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        uint256 sellerPk,
        uint256 platformPk,
        ICart.FulfillmentAction[] memory actions
    ) internal returns (NativePurchase memory purchase) {
        purchase.amount = listing.minimumUnitPrice * quantity;
        purchase.lines = _lineForListing(listing, quantity, purchase.amount);
        purchase.routes = _emptyRoutes(1);
        purchase.actions = actions;
        purchase.order = _order(orderId, purchase.lines, purchase.routes, purchase.actions);
        purchase.listings = _singletonListing(listing);
        purchase.authorization = _rootAuthorization(purchase.listings, sellerPk);
        purchase.platformSignature = _sign(platformPk, _orderDigest(purchase.order));
    }

    function _executeNative(NativePurchase memory purchase) internal {
        vm.deal(payer, purchase.amount);
        vm.prank(payer);
        cart.executePurchase{value: purchase.amount}(
            purchase.order,
            purchase.lines,
            purchase.listings,
            purchase.authorization,
            _combineRoutes(purchase.routes),
            purchase.actions,
            purchase.platformSignature
        );
    }

    function _noActions() internal pure returns (ICart.FulfillmentAction[] memory actions) {
        actions = new ICart.FulfillmentAction[](0);
    }
}
