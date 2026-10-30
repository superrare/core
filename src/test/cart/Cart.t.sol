// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Vm} from "forge-std/Vm.sol";

import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";

import {Cart} from "../../cart/Cart.sol";
import {ICart} from "../../cart/ICart.sol";

import {CartFixture} from "./CartFixture.sol";
import "./CartMocks.sol";

contract CartTest is CartFixture {
    function testAtomicNativeOffchainLineCapturesProtocolSpread() public {
        ICart.Listing memory listing =
            _listing(keccak256("offchain-listing"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingDigest: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("native-offchain", lines, route, actions);
        order.paymentAmount = 1.25 ether;
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        uint256 sourceBefore = payer.balance;
        uint256 protocolBefore = address(this).balance;

        vm.prank(payer);
        cart.executePurchase{value: 1.25 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(sellerPayout.balance, 1 ether);
        assertEq(payer.balance, sourceBefore - 1.25 ether);
        assertEq(address(this).balance, protocolBefore + 0.25 ether);
    }

    function testNativePayoutRejectsCartAsPaymentRecipient() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: keccak256("cart-self-payout"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: address(cart)
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("cart-self-payout", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidPaymentRecipient.selector, address(cart)));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertFalse(cart.executedOrderIds(order.orderId));
        assertEq(address(cart).balance, 0);
    }

    function testZeroListingDigestPreservesExplicitFulfillmentKind() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine({
            sku: keccak256("arbitrary-erc20"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.CURRENCY_SWAP,
            quantity: 1,
            settlementCurrency: address(weth),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        lines[1] = ICart.OrderLine({
            sku: keccak256("fee"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: collector
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("arbitrary-erc20", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        vm.deal(payer, 2 ether);
        vm.recordLogs();
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        bytes32 eventSignature =
            keccak256("OrderLineSettled(bytes32,uint256,bytes32,bytes32,uint256,address,uint256,address,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundSwap;
        bool foundFee;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            (,,,,, ICart.FulfillmentKind kind) =
                abi.decode(logs[i].data, (bytes32, uint256, address, uint256, address, ICart.FulfillmentKind));
            if (logs[i].topics[2] == bytes32(uint256(0))) {
                assertEq(uint8(kind), uint8(ICart.FulfillmentKind.CURRENCY_SWAP));
                foundSwap = true;
            } else if (logs[i].topics[2] == bytes32(uint256(1))) {
                assertEq(uint8(kind), uint8(ICart.FulfillmentKind.NONE));
                foundFee = true;
            }
        }
        assertTrue(foundSwap, "CURRENCY_SWAP settlement not emitted");
        assertTrue(foundFee, "NONE settlement not emitted");
    }

    function testCurrencySwapCannotBeSellerListing() public {
        ICart.Listing memory listing =
            _listing(keccak256("listed-swap"), ICart.FulfillmentKind.CURRENCY_SWAP, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("listed-swap", lines, route, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidListing.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );
    }

    function testOnChainListingsRejectTargetsWithoutCode() public {
        address codeLessTarget = address(0xBEEF);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        for (
            uint8 rawKind = uint8(ICart.FulfillmentKind.ERC721_TRANSFER);
            rawKind <= uint8(ICart.FulfillmentKind.ERC1155_MINT_TO);
            ++rawKind
        ) {
            ICart.FulfillmentKind kind = ICart.FulfillmentKind(rawKind);
            uint256 tokenId = kind == ICart.FulfillmentKind.ERC721_MINT_TO ? 0 : 1;
            ICart.Listing memory listing = _listing(
                keccak256(abi.encode("code-less-target", rawKind)), kind, codeLessTarget, tokenId, sellerPayout
            );

            ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
            ICart.PayoutRoute memory route = _emptyRoute();
            ICart.PurchaseOrder memory order =
                _order(string(abi.encodePacked("code-less-target-", rawKind)), lines, route, actions);
            ICart.Listing[] memory listings = _singletonListing(listing);
            ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
            bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

            vm.deal(payer, 1 ether);
            vm.expectRevert(ICart.InvalidListing.selector);
            vm.prank(payer);
            cart.executePurchase{value: 1 ether}(
                order, lines, listings, authorization, route, actions, platformSignature
            );
        }
    }

    function testMintListingsRejectContractOwnerMismatch() public {
        CartTestMintableERC721 erc721 = new CartTestMintableERC721();
        CartTestERC1155 erc1155 = new CartTestERC1155();
        address[2] memory targets = [address(erc721), address(erc1155)];

        for (uint256 i = 0; i < targets.length; ++i) {
            ICart.FulfillmentKind kind =
                i == 0 ? ICart.FulfillmentKind.ERC721_MINT_TO : ICart.FulfillmentKind.ERC1155_MINT_TO;
            ICart.Listing memory listing =
                _listing(keccak256(abi.encode("owner-mismatch", i)), kind, targets[i], i, sellerPayout);
            ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
            actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

            _executeNativeListingExpectRevert(
                listing,
                string(abi.encodePacked("owner-mismatch-", i)),
                1,
                actions,
                abi.encodeWithSelector(ICart.InvalidMintContractOwner.selector, targets[i], seller)
            );
        }
    }

    function testMintListingRejectsContractWithoutOwner() public {
        CartTestERC721 token = new CartTestERC721();
        ICart.Listing memory listing =
            _listing(keccak256("missing-owner"), ICart.FulfillmentKind.ERC721_MINT_TO, address(token), 0, sellerPayout);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        _executeNativeListingExpectRevert(
            listing,
            "missing-owner",
            1,
            actions,
            abi.encodeWithSelector(ICart.InvalidMintContractOwner.selector, address(token), listing.seller)
        );
    }

    function testCurrencySwapMustChangeCurrency() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: keccak256("same-currency-swap"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.CURRENCY_SWAP,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: collector
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("same-currency-swap", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingTermsMismatch.selector, 0));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );
    }

    function testRejectsZeroOrderId() public {
        ICart.Listing memory listing =
            _listing(keccak256("zero-order-id-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("zero-order-id", lines, route, actions);
        order.orderId = bytes32(0);

        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidOrderId.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertFalse(cart.executedOrderIds(bytes32(0)));
    }

    function testUnderfundedNativePurchaseCannotUsePreexistingWeth() public {
        // Keep the synthetic WETH solvent when the purchase attempts to withdraw
        // the pre-existing balance plus the newly deposited payment.
        vm.deal(address(weth), 1 ether);
        weth.mint(address(cart), 1 ether);

        ICart.Listing memory listing =
            _listing(keccak256("no-cart-subsidy"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 2 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("no-cart-subsidy", lines, route, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(weth.balanceOf(address(cart)), 1 ether);
        assertEq(sellerPayout.balance, 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testSuccessfulPurchasePreservesPreexistingCartBalances() public {
        weth.mint(address(cart), 3 ether);
        vm.deal(address(cart), 2 ether);

        ICart.Listing memory listing =
            _listing(keccak256("preserve-cart-balances"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "preserve-cart-balances", 1, actions);

        assertEq(weth.balanceOf(address(cart)), 3 ether);
        assertEq(address(cart).balance, 2 ether);
    }

    function testFulfillmentReceiverCannotReenterSellerInvalidation() public {
        CartTestERC721 token = new CartTestERC721();
        bytes32 listingSeed = keccak256("reentrant-seller-listing");
        ReentrantSellerReceiver sellerContract = new ReentrantSellerReceiver(cart, bytes32(0));
        token.mint(address(sellerContract), 1);
        sellerContract.approveCart(token, address(cart));

        ICart.Listing memory listing =
            _listing(listingSeed, ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout);
        listing.seller = address(sellerContract);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: address(sellerContract)});
        ICart.PurchaseOrder memory order = _order("reentrant-seller", lines, route, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        sellerContract.setRootDigest(hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), authorization.listingRoots[0]));
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertFalse(sellerContract.cancelRootCallSucceeded());
        assertFalse(sellerContract.nonceCallSucceeded());
        assertEq(cart.listingNonces(address(sellerContract)), 0);
    }

    function testErc721ReceiverCannotReenterPurchase() public {
        CartTestERC721 token = new CartTestERC721();
        ReentrantFulfillmentReceiver receiver = new ReentrantFulfillmentReceiver(cart);
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listing(
            keccak256("reentrant-721-purchase"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: address(receiver)});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-721-purchase", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        receiver.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                route,
                actions,
                platformSignature,
                1 ether
            )
        );

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(token.ownerOf(1), address(receiver));
    }

    function testErc1155ReceiverCannotReenterPurchase() public {
        CartTestERC1155 token = new CartTestERC1155();
        ReentrantFulfillmentReceiver receiver = new ReentrantFulfillmentReceiver(cart);
        token.mint(seller, 42, 2);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("reentrant-1155-purchase"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            2
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: address(receiver)});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-1155-purchase", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        receiver.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                route,
                actions,
                platformSignature,
                2 ether
            )
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertEq(token.balanceOf(address(receiver), 42), 2);
    }

    function testErc721TokenCannotReenterPurchase() public {
        ReentrantERC721 token = new ReentrantERC721(cart);
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listing(
            keccak256("reentrant-721-token"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-721-token", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        token.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                route,
                actions,
                platformSignature,
                1 ether
            )
        );

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(token.ownerOf(1), collector);
    }

    function testErc1155TokenCannotReenterPurchase() public {
        ReentrantERC1155 token = new ReentrantERC1155(cart);
        token.mint(seller, 42, 2);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("reentrant-1155-token"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            2
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-1155-token", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        token.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                route,
                actions,
                platformSignature,
                2 ether
            )
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertEq(token.balanceOf(collector, 42), 2);
    }

    function testUniversalRouterSubsidyBecomesProtocolSpread() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("router-subsidy");
        outputToken.mint(address(router), 1 ether);
        router.configure(address(outputToken), 1 ether, 0, true);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute memory route) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("router-subsidy", lines, route, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 1 ether);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
    }

    function testUniversalRouterConsumesPermit2InputAndCapturesExactOutputSpread() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("permit2-exact-output");

        address inputSink = address(0x6001);
        router.configureSettlement(
            address(permit2), inputSink, address(inputToken), address(outputToken), 1 ether, 1 ether
        );
        outputToken.mint(address(router), 1 ether);

        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _emptyRoute();
        address[] memory path = new address[](2);
        path[0] = address(inputToken);
        path[1] = address(outputToken);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1.25 ether, path, true);
        route = ICart.PayoutRoute({commands: hex"09", inputs: inputs, routerValue: 0});

        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("permit2-exact-output", lines, route, actions);
        order.paymentCurrency = address(inputToken);
        order.paymentAmount = 1.25 ether;
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1.25 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1.25 ether);

        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        // The router spent 1 token through Permit2 and Cart captured the unused 0.25-token
        // fixed-quote spread for the protocol.
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 0.25 ether);
        assertEq(inputToken.balanceOf(inputSink), 1 ether);
        assertEq(inputToken.balanceOf(address(cart)), 0);
        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
        assertTrue(cart.executedOrderIds(order.orderId));
    }

    function testOrderLineSettledReportsActualPaymentAndFulfillmentKind() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("authoritative-settlement-event");
        router.configure(address(outputToken), 2 ether, 0, false);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute memory route) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("authoritative-settlement-event", lines, route, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.recordLogs();
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        bytes32 eventSignature =
            keccak256("OrderLineSettled(bytes32,uint256,bytes32,bytes32,uint256,address,uint256,address,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            assertEq(logs[i].topics[1], order.orderId);
            assertEq(logs[i].topics[2], bytes32(uint256(0)));
            assertEq(logs[i].topics[3], listing.sku);
            assertEq(
                logs[i].data,
                abi.encode(
                    _listingDigest(listing),
                    uint256(1),
                    address(outputToken),
                    uint256(1 ether),
                    sellerPayout,
                    ICart.FulfillmentKind.NONE
                )
            );
            found = true;
        }
        assertTrue(found, "OrderLineSettled not emitted");
    }

    function testOrderWideRouteSupportsMultipleOutputsAndSendsSurplusToProtocol() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputA = new CartTestToken("Output A", "OA");
        CartTestToken outputB = new CartTestToken("Output B", "OB");

        ICart.Listing memory listingA =
            _listing(keccak256("order-wide-a"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingA.settlementCurrency = address(outputA);
        ICart.Listing memory listingB =
            _listing(keccak256("order-wide-b"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingB.settlementCurrency = address(outputB);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listingA;
        listings[1] = listingB;

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listingA, 1, 1 ether)[0];
        lines[1] = _lineForListing(listingB, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(outputA);
        lines[1].settlementCurrency = address(outputB);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputA), address(outputB), 0.5 ether, 0.5 ether, false);
        address[] memory tokens = new address[](2);
        tokens[0] = address(outputA);
        tokens[1] = address(outputB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 3 ether;
        router.configureMulti(tokens, amounts);

        ICart.PurchaseOrder memory order = _orderSingle("order-wide-multi-output", inputToken, lines, route, 1 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(outputA.balanceOf(sellerPayout), 1 ether);
        assertEq(outputB.balanceOf(sellerPayout), 1 ether);
        assertEq(outputA.balanceOf(address(this)), 1 ether);
        assertEq(outputB.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.balanceOf(address(this)), 1 ether);
        assertEq(router.executeCalls(), 1);
        assertEq(inputToken.balanceOf(payer), 0);
    }

    function testOrderWideRouteSupportsMixedDirectAndSwapLines() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");

        ICart.Listing memory directListing =
            _listing(keccak256("order-wide-direct"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        directListing.settlementCurrency = address(inputToken);
        ICart.Listing memory swapListing =
            _listing(keccak256("order-wide-swap"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        swapListing.settlementCurrency = address(outputToken);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = directListing;
        listings[1] = swapListing;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(directListing, 1, 1 ether)[0];
        lines[1] = _lineForListing(swapListing, 1, 2 ether)[0];
        lines[0].settlementCurrency = address(inputToken);
        lines[1].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputToken), address(0), 2 ether, 0, false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(outputToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3 ether;
        router.configureMulti(tokens, amounts);
        ICart.PurchaseOrder memory order = _orderSingle("order-wide-mixed", inputToken, lines, route, 3 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 3 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 3 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(inputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(sellerPayout), 2 ether);
        assertEq(outputToken.balanceOf(address(this)), 1 ether);
        assertEq(inputToken.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.balanceOf(payer), 0);
    }

    function testOrderWideExactOutputRouteCapturesUnusedInputAsProtocolSpread() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputA = new CartTestToken("Output A", "OA");
        CartTestToken outputB = new CartTestToken("Output B", "OB");
        ICart.Listing memory listingA =
            _listing(keccak256("order-wide-exact-a"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingA.settlementCurrency = address(outputA);
        ICart.Listing memory listingB =
            _listing(keccak256("order-wide-exact-b"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingB.settlementCurrency = address(outputB);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listingA;
        listings[1] = listingB;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listingA, 1, 1 ether)[0];
        lines[1] = _lineForListing(listingB, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(outputA);
        lines[1].settlementCurrency = address(outputB);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputA), address(outputB), 1 ether, 1 ether, true);
        address[] memory tokens = new address[](2);
        tokens[0] = address(outputA);
        tokens[1] = address(outputB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        router.configureMulti(tokens, amounts);
        ICart.PurchaseOrder memory order = _orderSingle("order-wide-exact-output", inputToken, lines, route, 2 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 2 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 2 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(outputA.balanceOf(sellerPayout), 1 ether);
        assertEq(outputB.balanceOf(sellerPayout), 1 ether);
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
    }

    function testIncidentalUniversalRouterTokenBalanceDoesNotBlockSettlement() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("router-retention");
        router.configure(address(outputToken), 1 ether, 1 ether, false);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute memory route) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("router-retention", lines, route, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(outputToken.balanceOf(address(router)), 1 ether);
        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(cart)), 0);
    }

    function testAtomicNftFulfillmentRollsBackOnPayoutFailure() public {
        CartTestERC721 token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        RevertingPayoutRecipient revertingRecipient = new RevertingPayoutRecipient();

        ICart.Listing memory listing = _listing(
            keccak256("nft-listing"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(token),
            1,
            address(revertingRecipient)
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingDigest: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: address(revertingRecipient)
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("nft-rollback", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, bytes("")));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(token.ownerOf(1), seller);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testSellerNonceInvalidationRejectsPreviouslySignedListing() public {
        ICart.Listing memory listing =
            _listing(keccak256("invalidated-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingDigest: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("invalidated", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.prank(seller);
        cart.invalidateListingNonce();

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidListingNonce.selector, 1, 0));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );
    }

    function testErc1155TransferFulfillsRequestedQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 3);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("1155-transfer"), ICart.FulfillmentKind.ERC1155_TRANSFER, address(token), 42, sellerPayout, 3
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("1155-transfer-order", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(token.balanceOf(collector, 42), 2);
        assertEq(token.balanceOf(seller, 42), 1);
    }

    function testErc1155MintToFulfillsQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("1155-mint"), ICart.FulfillmentKind.ERC1155_MINT_TO, address(token), 7, sellerPayout, 3
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("1155-mint-order", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        ICart.MintResult[] memory mintResults = cart.executePurchase{value: 2 ether}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );

        assertEq(token.balanceOf(collector, 7), 2);
        assertEq(mintResults.length, 0);
    }

    function testUncappedOffchainListingCanBeFilledRepeatedly() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-offchain"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "uncapped-offchain-one", 1, actions);
        _executeNativeListing(listing, "uncapped-offchain-two", 2, actions);

        assertEq(cart.filledQuantity(_listingDigest(listing)), 3);
    }

    function testUncappedNoneListingCanBeFilledRepeatedly() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-none"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "uncapped-none-one", 1, actions);
        _executeNativeListing(listing, "uncapped-none-two", 1, actions);

        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc721TransferCanReviveWhenTokenReturns() public {
        CartTestERC721 token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-721-transfer"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(token),
            1,
            sellerPayout,
            0
        );

        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        _executeNativeListing(listing, "uncapped-721-first", 1, actions);
        assertEq(token.ownerOf(1), collector);

        ICart.OrderLine[] memory unavailableLines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory unavailableRoute = _emptyRoute();
        ICart.FulfillmentAction[] memory unavailableActions = new ICart.FulfillmentAction[](1);
        unavailableActions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.PurchaseOrder memory unavailableOrder =
            _order("uncapped-721-unavailable", unavailableLines, unavailableRoute, unavailableActions);
        bytes memory unavailablePlatformSignature = _sign(PLATFORM_PK, _orderDigest(unavailableOrder));
        ICart.Listing[] memory unavailableListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory unavailableAuthorization =
            _rootAuthorization(unavailableListings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                uint256(0),
                uint256(0),
                abi.encodeWithSignature("Error(string)", "ERC721: caller is not token owner or approved")
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            unavailableOrder,
            unavailableLines,
            unavailableListings,
            unavailableAuthorization,
            unavailableRoute,
            unavailableActions,
            unavailablePlatformSignature
        );

        vm.prank(collector);
        token.safeTransferFrom(collector, seller, 1);
        _executeNativeListing(listing, "uncapped-721-returned", 1, actions);

        assertEq(token.ownerOf(1), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc1155TransferCanReviveWhenBalanceReturns() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-1155-transfer"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        _executeNativeListing(listing, "uncapped-1155-first", 1, actions);
        assertEq(token.balanceOf(seller, 42), 0);

        ICart.OrderLine[] memory unavailableLines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory unavailableRoute = _emptyRoute();
        ICart.FulfillmentAction[] memory unavailableActions = new ICart.FulfillmentAction[](1);
        unavailableActions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.PurchaseOrder memory unavailableOrder =
            _order("uncapped-1155-unavailable", unavailableLines, unavailableRoute, unavailableActions);
        bytes memory unavailablePlatformSignature = _sign(PLATFORM_PK, _orderDigest(unavailableOrder));
        ICart.Listing[] memory unavailableListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory unavailableAuthorization =
            _rootAuthorization(unavailableListings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                uint256(0),
                uint256(0),
                abi.encodeWithSignature("Error(string)", "ERC1155: insufficient balance for transfer")
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            unavailableOrder,
            unavailableLines,
            unavailableListings,
            unavailableAuthorization,
            unavailableRoute,
            unavailableActions,
            unavailablePlatformSignature
        );

        vm.prank(collector);
        token.safeTransferFrom(collector, seller, 42, 1, "");
        _executeNativeListing(listing, "uncapped-1155-returned", 1, actions);

        assertEq(token.balanceOf(seller, 42), 0);
        assertEq(token.balanceOf(collector, 42), 1);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc1155MintToDoesNotUseFilledQuantityAsLimit() public {
        CartTestERC1155 token = new CartTestERC1155();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-1155-mint"), ICart.FulfillmentKind.ERC1155_MINT_TO, address(token), 7, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});

        _executeNativeListing(listing, "uncapped-1155-mint-one", 2, actions);
        _executeNativeListing(listing, "uncapped-1155-mint-two", 2, actions);

        assertEq(token.balanceOf(collector, 7), 4);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 4);
    }

    function testUncappedErc721MintToDoesNotUseFilledQuantityAsLimit() public {
        CartTestMintableERC721 token = new CartTestMintableERC721();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-721-mint"), ICart.FulfillmentKind.ERC721_MINT_TO, address(token), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        _executeNativeListing(listing, "uncapped-721-mint-one", 1, actions);
        _executeNativeListing(listing, "uncapped-721-mint-two", 1, actions);

        assertEq(token.ownerOf(1), collector);
        assertEq(token.ownerOf(2), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testFulfillmentEventsIdentifyEveryMintedToken() public {
        CartTestMintableERC721 token = new CartTestMintableERC721();
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("authoritative-mint-events"),
            ICart.FulfillmentKind.ERC721_MINT_TO,
            address(token),
            0,
            sellerPayout,
            2
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});

        vm.recordLogs();
        ICart.MintResult[] memory mintResults = _executeNativeListing(listing, "authoritative-mint-events", 2, actions);

        assertEq(mintResults.length, 1);
        assertEq(mintResults[0].fulfillmentActionIndex, 0);
        assertEq(mintResults[0].tokenIds.length, 2);
        assertEq(mintResults[0].tokenIds[0], 1);
        assertEq(mintResults[0].tokenIds[1], 2);

        bytes32 eventSignature = keccak256(
            "FulfillmentActionExecuted(bytes32,uint256,uint256,uint8,address,address,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 eventCount;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            assertEq(logs[i].topics[1], keccak256("authoritative-mint-events"));
            assertEq(logs[i].topics[2], bytes32(uint256(0)));
            assertEq(logs[i].topics[3], bytes32(uint256(0)));
            assertEq(
                logs[i].data,
                abi.encode(
                    ICart.FulfillmentKind.ERC721_MINT_TO,
                    address(token),
                    collector,
                    uint256(1),
                    eventCount + 1,
                    eventCount
                )
            );
            ++eventCount;
        }
        assertEq(eventCount, 2);
    }

    function testMintResultsIdentifyActionsAcrossCollectionsAndSplitDeliveries() public {
        CartTestERC721 transferToken = new CartTestERC721();
        transferToken.mint(seller, 99);
        vm.prank(seller);
        transferToken.setApprovalForAll(address(cart), true);

        CartTestMintableERC721 mintA = new CartTestMintableERC721();
        CartTestMintableERC721 mintB = new CartTestMintableERC721();
        CartTestERC1155 mint1155 = new CartTestERC1155();
        mintA.transferOwnership(seller);
        mintB.transferOwnership(seller);
        mint1155.transferOwnership(seller);
        vm.startPrank(seller);
        mintA.setMinter(address(cart), true);
        mintB.setMinter(address(cart), true);
        mint1155.setMinter(address(cart), true);
        // Returned IDs must reflect collection state, rather than start at one per action.
        mintA.mintTo(seller);
        vm.stopPrank();

        ICart.Listing[] memory listings = new ICart.Listing[](4);
        listings[0] = _listingWithQuantity(
            keccak256("mint-result-a"), ICart.FulfillmentKind.ERC721_MINT_TO, address(mintA), 0, sellerPayout, 3
        );
        listings[1] = _listing(
            keccak256("mint-result-transfer"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(transferToken),
            99,
            sellerPayout
        );
        listings[2] = _listingWithQuantity(
            keccak256("mint-result-1155"), ICart.FulfillmentKind.ERC1155_MINT_TO, address(mint1155), 7, sellerPayout, 2
        );
        listings[3] =
            _listing(keccak256("mint-result-b"), ICart.FulfillmentKind.ERC721_MINT_TO, address(mintB), 0, sellerPayout);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](4);
        lines[0] = _lineForListing(listings[0], 3, 3 ether)[0];
        lines[1] = _lineForListing(listings[1], 1, 1 ether)[0];
        lines[2] = _lineForListing(listings[2], 2, 2 ether)[0];
        lines[3] = _lineForListing(listings[3], 1, 1 ether)[0];
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](5);
        actions[0] = ICart.FulfillmentAction({lineIndex: 1, quantity: 1, recipient: collector});
        actions[1] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        actions[2] = ICart.FulfillmentAction({lineIndex: 2, quantity: 2, recipient: collector});
        actions[3] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: payer});
        actions[4] = ICart.FulfillmentAction({lineIndex: 3, quantity: 1, recipient: collector});
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.PurchaseOrder memory order = _order("mixed-mint-results", lines, route, actions);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 7 ether);
        vm.prank(payer);
        ICart.MintResult[] memory mintResults = ICart(address(cart)).executePurchase{value: 7 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );

        assertEq(mintResults.length, 3);
        assertEq(mintResults[0].fulfillmentActionIndex, 1);
        assertEq(mintResults[0].tokenIds.length, 2);
        assertEq(mintResults[0].tokenIds[0], 2);
        assertEq(mintResults[0].tokenIds[1], 3);
        assertEq(mintResults[1].fulfillmentActionIndex, 3);
        assertEq(mintResults[1].tokenIds.length, 1);
        assertEq(mintResults[1].tokenIds[0], 4);
        assertEq(mintResults[2].fulfillmentActionIndex, 4);
        assertEq(mintResults[2].tokenIds.length, 1);
        assertEq(mintResults[2].tokenIds[0], 1);
        assertEq(mintA.ownerOf(2), collector);
        assertEq(mintA.ownerOf(3), collector);
        assertEq(mintA.ownerOf(4), payer);
        assertEq(mintB.ownerOf(1), collector);
        assertEq(transferToken.ownerOf(99), collector);
        assertEq(mint1155.balanceOf(collector, 7), 2);
        assertEq(sellerPayout.balance, 7 ether);
    }

    function testPurchaseWithoutFulfillmentReturnsEmptyMintResults() public {
        ICart.Listing memory listing =
            _listing(keccak256("empty-mint-results"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);

        ICart.MintResult[] memory mintResults =
            _executeNativeListing(listing, "empty-mint-results", 1, new ICart.FulfillmentAction[](0));

        assertEq(mintResults.length, 0);
        assertEq(sellerPayout.balance, 1 ether);
    }

    function testTooManyListingsAreRejectedBeforeVerification() public {
        ICart.Listing memory referencedListing =
            _listing(keccak256("referenced"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory strayListing =
            _listing(keccak256("stray"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);

        ICart.OrderLine[] memory lines = _lineForListing(referencedListing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = referencedListing;
        listings[1] = strayListing;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        ICart.PurchaseOrder memory order = _order("stray-listing", lines, route, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidArrayLength.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, route, actions, platformSignature
        );
    }

}
