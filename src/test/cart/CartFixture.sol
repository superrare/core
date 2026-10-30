// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Cart} from "../../cart/Cart.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {CartHashes} from "../../cart/CartHashes.sol";
import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {ICart} from "../../cart/ICart.sol";

import "./CartMocks.sol";

/// @notice Shared deployment, signing, and purchase builders without executable tests.
abstract contract CartFixture is Test {
    uint256 internal constant PLATFORM_PK = 0xA11CE;
    uint256 internal constant SELLER_PK = 0xB0B;
    uint256 internal constant PAYER_PK = 0xC0FFEE;

    address internal platformSigner;
    address internal seller;
    address internal payer;
    address internal sellerPayout = address(0x5001);
    address internal collector = address(0x5002);

    Cart internal cart;
    CartHashes internal hashes;
    CartRoutePolicy internal routePolicy;
    CartPayments internal paymentExecutor;
    CartTestWETH internal weth;
    CartTestRouter internal router;
    CartTestPermit2 internal permit2;

    function setUp() public {
        // Derive the platform, seller, and payer identities used by signed fixtures.
        platformSigner = vm.addr(PLATFORM_PK);
        seller = vm.addr(SELLER_PK);
        payer = vm.addr(PAYER_PK);
        // Deploy the deterministic settlement dependencies and canonical hashing helper.
        weth = new CartTestWETH();
        router = new CartTestRouter();
        permit2 = new CartTestPermit2();
        hashes = new CartHashes();
        routePolicy = new CartRoutePolicy();
        paymentExecutor = new CartPayments(address(routePolicy));

        // Initialize one proxy so signatures and approvals use its stable address.
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData = abi.encodeCall(
            Cart.initialize, (address(this), platformSigner, address(router), address(permit2), address(weth))
        );
        cart = Cart(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _listing(
        bytes32 listingSeed,
        ICart.FulfillmentKind fulfillmentKind,
        address tokenContract,
        uint256 tokenId,
        address paymentRecipient
    ) internal view returns (ICart.Listing memory) {
        return _listingWithQuantity(listingSeed, fulfillmentKind, tokenContract, tokenId, paymentRecipient, 1);
    }

    function _listingWithQuantity(
        bytes32 listingSeed,
        ICart.FulfillmentKind fulfillmentKind,
        address tokenContract,
        uint256 tokenId,
        address paymentRecipient,
        uint256 availableQuantity
    ) internal view returns (ICart.Listing memory) {
        return ICart.Listing({
            listingSalt: listingSeed,
            seller: seller,
            sku: keccak256(abi.encodePacked("sku-", listingSeed)),
            fulfillmentKind: fulfillmentKind,
            tokenContract: tokenContract,
            tokenId: tokenId,
            settlementCurrency: address(0),
            minimumUnitPrice: 1 ether,
            availableQuantity: availableQuantity,
            paymentRecipient: paymentRecipient
        });
    }

    function _lineForListing(ICart.Listing memory listing, uint256 quantity, uint256 amount)
        internal
        view
        returns (ICart.OrderLine[] memory lines)
    {
        lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingDigest: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: quantity,
            settlementCurrency: address(0),
            amount: amount,
            paymentRecipient: listing.paymentRecipient
        });
    }

    function _executeNativeListing(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        ICart.FulfillmentAction[] memory actions
    ) internal returns (ICart.MintResult[] memory mintResults) {
        uint256 amount = listing.minimumUnitPrice * quantity;
        ICart.OrderLine[] memory lines = _lineForListing(listing, quantity, amount);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.PurchaseOrder memory order = _order(orderId, lines, route, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, amount);
        vm.prank(payer);
        return cart.executePurchase{value: amount}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );
    }

    function _executeNativeListingExpectRevert(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        ICart.FulfillmentAction[] memory actions,
        bytes memory reason
    ) internal {
        uint256 amount = listing.minimumUnitPrice * quantity;
        ICart.OrderLine[] memory lines = _lineForListing(listing, quantity, amount);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.PurchaseOrder memory order = _order(orderId, lines, route, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, amount);
        vm.expectRevert(reason);
        vm.prank(payer);
        cart.executePurchase{value: amount}(
            order, lines, authorizationListings, authorization, route, actions, platformSignature
        );
    }

    function _order(
        string memory id,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        ICart.FulfillmentAction[] memory actions
    ) internal view returns (ICart.PurchaseOrder memory) {
        uint256 paymentAmount;
        for (uint256 i = 0; i < lines.length; ++i) {
            paymentAmount += lines[i].amount;
        }
        return ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(0),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
    }

    function _orderSingle(
        string memory id,
        CartTestToken inputToken,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        uint256 paymentAmount
    ) internal view returns (ICart.PurchaseOrder memory) {
        return ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(inputToken),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(new ICart.FulfillmentAction[](0))
        });
    }

    function _multiOutputRoute(
        address inputToken,
        address outputA,
        address outputB,
        uint256 amountA,
        uint256 amountB,
        bool exactOutput
    ) internal pure returns (ICart.PayoutRoute memory route) {
        uint256 count = amountB == 0 ? 1 : 2;
        route.commands = new bytes(count);
        route.inputs = new bytes[](count);
        route.commands[0] = exactOutput ? bytes1(0x09) : bytes1(0x08);
        address[] memory pathA = new address[](2);
        pathA[0] = inputToken;
        pathA[1] = outputA;
        route.inputs[0] = abi.encode(address(1), amountA, amountA, pathA, true);
        if (count == 2) {
            route.commands[1] = exactOutput ? bytes1(0x09) : bytes1(0x08);
            address[] memory pathB = new address[](2);
            pathB[0] = inputToken;
            pathB[1] = outputB;
            route.inputs[1] = abi.encode(address(1), amountB, amountB, pathB, true);
        }
    }

    function _routedTokensAndListing(string memory id)
        internal
        returns (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing)
    {
        inputToken = new CartTestToken("Input", "IN");
        outputToken = new CartTestToken("Output", "OUT");
        listing = _listing(keccak256(bytes(id)), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
    }

    function _routedLineAndRoute(ICart.Listing memory listing, address inputToken, address outputToken)
        internal
        view
        returns (ICart.OrderLine[] memory lines, ICart.PayoutRoute memory route)
    {
        lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = outputToken;
        address[] memory path = new address[](2);
        path[0] = inputToken;
        path[1] = outputToken;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        route = ICart.PayoutRoute({commands: hex"08", inputs: inputs, routerValue: 0});
    }

    function _listingDigest(ICart.Listing memory listing) internal view returns (bytes32) {
        return hashes.hashListing(cart.DOMAIN_SEPARATOR(), listing);
    }

    function _orderDigest(ICart.PurchaseOrder memory order) internal view returns (bytes32) {
        return hashes.hashOrder(cart.DOMAIN_SEPARATOR(), order);
    }

    /// @dev Direct settlement needs no router commands, inputs, or native router value.
    function _emptyRoute() internal pure returns (ICart.PayoutRoute memory route) {
        route = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0), routerValue: 0});
    }

    function _singletonListing(ICart.Listing memory listing) internal pure returns (ICart.Listing[] memory listings) {
        listings = new ICart.Listing[](1);
        listings[0] = listing;
    }

    function _rootAuthorization(ICart.Listing[] memory listings, uint256 sellerPk)
        internal
        returns (ICart.ListingPurchaseAuthorization memory authorization)
    {
        authorization.listingRoots = new ICart.ListingRoot[](listings.length);
        authorization.listingRootSignatures = new bytes[](listings.length);
        authorization.listingRootIndexes = new uint256[](listings.length);
        authorization.listingProofs = new bytes32[][](listings.length);
        for (uint256 i = 0; i < listings.length; ++i) {
            ICart.Listing memory listing = listings[i];
            ICart.ListingRoot memory root = ICart.ListingRoot({
                listingsRoot: hashes.hashListingLeaf(_listingDigest(listing)),
                nonce: 0,
                deadline: block.timestamp + 1 days
            });
            authorization.listingRoots[i] = root;
            authorization.listingRootSignatures[i] =
                _sign(sellerPk, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root));
            authorization.listingRootIndexes[i] = i;
            authorization.listingProofs[i] = new bytes32[](0);
        }
    }

    function _singletonBytes(bytes memory value) internal pure returns (bytes[] memory values) {
        values = new bytes[](1);
        values[0] = value;
    }

    function _sign(uint256 privateKey, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}
