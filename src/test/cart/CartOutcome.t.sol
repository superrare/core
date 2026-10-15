// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";

import {
    CartTest,
    CartTestERC721,
    CartTestFeeOnTransferToken,
    CartTestPermit2,
    CartTestRevertingTransferToken,
    CartTestRouter,
    CartTestToken,
    CartTestWETH
} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";
import {IPermit2Cart} from "../../cart/IPermit2Cart.sol";

contract CartAllowanceObserver is IERC721Receiver {
    address public immutable cart;
    address public immutable paymentToken;
    address public immutable permit2;
    address public immutable router;
    uint256 public observedCartAllowance;
    uint160 public observedPermit2Allowance;

    constructor(address cart_, address paymentToken_, address permit2_, address router_) {
        cart = cart_;
        paymentToken = paymentToken_;
        permit2 = permit2_;
        router = router_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        observedCartAllowance = IERC20(paymentToken).allowance(cart, permit2);
        (observedPermit2Allowance,,) = IPermit2Cart(permit2).allowance(cart, paymentToken, router);
        return this.onERC721Received.selector;
    }
}

/// @notice Outcome-level coverage for Cart's opaque Universal Router settlement boundary.
contract CartOutcomeTest is CartTest {
    function testDirectEthAndRoutedOutputsSettleTogether() public {
        CartTestToken usdc = new CartTestToken("USD Coin", "USDC");
        CartTestToken dai = new CartTestToken("Dai", "DAI");
        vm.deal(address(cart), 3 ether);
        weth.mint(address(cart), 2 ether);
        usdc.mint(address(cart), 5 ether);
        dai.mint(address(cart), 6 ether);
        ICart.Listing memory ethListing =
            _listing(keccak256("outcome-eth"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory usdcListing =
            _listing(keccak256("outcome-usdc"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        usdcListing.settlementCurrency = address(usdc);
        ICart.Listing memory daiListing =
            _listing(keccak256("outcome-dai"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        daiListing.settlementCurrency = address(dai);

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](3);
        lines[0] = _lineForListing(ethListing, 1, 2 ether)[0];
        lines[1] = _lineForListing(usdcListing, 1, 3 ether)[0];
        lines[1].settlementCurrency = address(usdc);
        lines[2] = _lineForListing(daiListing, 1, 4 ether)[0];
        lines[2].settlementCurrency = address(dai);
        ICart.Listing[] memory listings = new ICart.Listing[](3);
        listings[0] = ethListing;
        listings[1] = usdcListing;
        listings[2] = daiListing;
        ICart.PayoutRoute memory route = _opaqueRoute(hex"0b", 5 ether);
        router.configureMulti(_tokens(address(usdc), address(dai)), _amounts(3 ether, 4 ether));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("direct-eth-and-routed", lines, route, actions, 9 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        uint256 sellerEthBefore = sellerPayout.balance;
        uint256 collectorDaiBefore = dai.balanceOf(collector);
        uint256 protocolEthBefore = address(this).balance;
        vm.deal(payer, 9 ether);
        vm.prank(payer);
        cart.executePurchase{value: 9 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(sellerPayout.balance, sellerEthBefore + 2 ether);
        assertEq(usdc.balanceOf(sellerPayout), 3 ether);
        assertEq(dai.balanceOf(collector), collectorDaiBefore + 4 ether);
        assertEq(address(this).balance, protocolEthBefore + 2 ether);
        assertEq(address(cart).balance, 3 ether);
        assertEq(weth.balanceOf(address(cart)), 2 ether);
        assertEq(usdc.balanceOf(address(cart)), 5 ether);
        assertEq(dai.balanceOf(address(cart)), 6 ether);
        assertEq(router.lastRouterValue(), 5 ether);
    }

    function testPreexistingBalancesCannotFundPayouts() public {
        CartTestToken usdc = new CartTestToken("USD Coin", "USDC");
        CartTestToken dai = new CartTestToken("Dai", "DAI");
        weth.mint(address(cart), 2 ether);
        vm.deal(address(cart), 3 ether);
        usdc.mint(address(cart), 5 ether);
        dai.mint(address(cart), 6 ether);
        ICart.Listing memory usdcListing =
            _listing(keccak256("baseline-usdc"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        usdcListing.settlementCurrency = address(usdc);
        ICart.Listing memory daiListing =
            _listing(keccak256("baseline-dai"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        daiListing.settlementCurrency = address(dai);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(usdcListing, 1, 2 ether)[0];
        lines[0].settlementCurrency = address(usdc);
        lines[1] = _lineForListing(daiListing, 1, 3 ether)[0];
        lines[1].settlementCurrency = address(dai);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = usdcListing;
        listings[1] = daiListing;
        ICart.PayoutRoute memory route = _opaqueRoute(hex"10", 0);
        router.configureMulti(_tokens(address(usdc), address(dai)), _amounts(1 ether, 3 ether));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("baseline-cannot-fund", lines, route, actions, 5 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, abi.encode(1 ether, 2 ether)
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 5 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(address(cart).balance, 3 ether);
        assertEq(weth.balanceOf(address(cart)), 2 ether);
        assertEq(usdc.balanceOf(address(cart)), 5 ether);
        assertEq(dai.balanceOf(address(cart)), 6 ether);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testArbitraryRouterRecipientCannotBypassSolvency() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        address arbitraryRecipient = address(0x7001);
        ICart.Listing memory listing =
            _listing(keccak256("arbitrary-router-recipient"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 0);
        router.configureMultiTo(_tokens(address(outputToken)), _amounts(1 ether), _recipients(arbitraryRecipient));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("arbitrary-router-recipient", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, abi.encode(0, 1 ether)
            )
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(paymentToken.balanceOf(payer), 1 ether);
        assertEq(outputToken.balanceOf(arbitraryRecipient), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testDirectPaymentCurrencyObligationsRemainFunded() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        ICart.Listing memory directListing =
            _listing(keccak256("direct-payment-line"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        directListing.settlementCurrency = address(paymentToken);
        ICart.Listing memory routedListing =
            _listing(keccak256("routed-payment-line"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        routedListing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(directListing, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(paymentToken);
        lines[1] = _lineForListing(routedListing, 1, 1 ether)[0];
        lines[1].settlementCurrency = address(outputToken);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = directListing;
        listings[1] = routedListing;
        address inputSink = address(0x7002);
        router.configureSettlement(
            address(permit2), inputSink, address(paymentToken), address(outputToken), 2 ether, 1 ether
        );
        outputToken.mint(address(router), 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"09", 0);
        address[] memory path = new address[](2);
        path[0] = address(paymentToken);
        path[1] = address(outputToken);
        route.inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("direct-payment-not-funded", paymentToken, lines, route, 2 ether, actions);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 2 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, abi.encode(0, 1 ether)
            )
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(paymentToken.balanceOf(payer), 2 ether);
        assertEq(paymentToken.balanceOf(inputSink), 0);
        assertEq(outputToken.balanceOf(collector), 0);
    }

    function testEthAndWethCombinedCoverNativeFamily() public {
        vm.deal(address(weth), 1 ether);
        ICart.Listing memory ethListing =
            _listing(keccak256("native-family-eth"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory wethListing =
            _listing(keccak256("native-family-weth"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        wethListing.settlementCurrency = address(weth);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(ethListing, 1, 2 ether)[0];
        lines[1] = _lineForListing(wethListing, 1, 3 ether)[0];
        lines[1].settlementCurrency = address(weth);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = ethListing;
        listings[1] = wethListing;
        router.configureMulti(_tokens(address(weth)), _amounts(4 ether));
        ICart.PayoutRoute memory route = _opaqueRoute(hex"10", 4 ether);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("native-family-combined", lines, route, actions, 5 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 5 ether);
        vm.prank(payer);
        cart.executePurchase{value: 5 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(sellerPayout.balance, 2 ether);
        assertEq(weth.balanceOf(collector), 3 ether);
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
    }

    function testEthAndWethCombinedShortfallPreservesNonzeroBaselines() public {
        vm.deal(address(cart), 1 ether);
        weth.mint(address(cart), 2 ether);
        vm.deal(address(router), 0.5 ether);

        ICart.Listing memory ethListing =
            _listing(keccak256("native-family-shortfall-eth"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory wethListing =
            _listing(keccak256("native-family-shortfall-weth"), ICart.FulfillmentKind.NONE, address(0), 0, collector);
        wethListing.settlementCurrency = address(weth);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(ethListing, 1, 2 ether)[0];
        lines[1] = _lineForListing(wethListing, 1, 2 ether)[0];
        lines[1].settlementCurrency = address(weth);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = ethListing;
        listings[1] = wethListing;
        router.configureMulti(_tokens(address(0), address(weth)), _amounts(0.5 ether, 2 ether));
        ICart.PayoutRoute memory route = _opaqueRoute(hex"10", 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _orderWithRoute("native-family-shortfall", lines, route, actions, 1 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, abi.encode(3.5 ether, 4 ether)
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(address(cart).balance, 1 ether);
        assertEq(weth.balanceOf(address(cart)), 2 ether);
        assertEq(sellerPayout.balance, 0);
        assertEq(weth.balanceOf(collector), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testWethIsUnwrappedOnlyForEthShortfall() public {
        vm.deal(address(cart), 1 ether);
        weth.mint(address(cart), 5 ether);
        vm.deal(address(weth), 2 ether);
        ICart.Listing memory listing =
            _listing(keccak256("unwrap-positive-delta"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 2 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"0b", 2 ether);
        router.configureMulti(_tokens(address(weth)), _amounts(2 ether));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("unwrap-positive-delta", lines, route, actions, 2 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(address(cart).balance, 1 ether);
        assertEq(weth.balanceOf(address(cart)), 5 ether);
        assertEq(sellerPayout.balance, 2 ether);
    }

    function testEthIsWrappedOnlyForWethShortfall() public {
        vm.deal(address(cart), 1 ether);
        weth.mint(address(cart), 5 ether);
        ICart.Listing memory listing =
            _listing(keccak256("wrap-positive-delta"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(weth);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 2 ether);
        lines[0].settlementCurrency = address(weth);
        ICart.PayoutRoute memory route = _opaqueRoute(bytes(""), 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("wrap-positive-delta", lines, route, actions, 2 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(address(cart).balance, 1 ether);
        assertEq(weth.balanceOf(address(cart)), 5 ether);
        assertEq(weth.balanceOf(sellerPayout), 2 ether);
    }

    function testNativeFamilySpreadCaptured() public {
        ICart.Listing memory listing =
            _listing(keccak256("native-family-spread"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(bytes(""), 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("native-family-spread", lines, route, actions, 3 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        uint256 protocolBefore = address(this).balance;

        vm.deal(payer, 3 ether);
        vm.prank(payer);
        cart.executePurchase{value: 3 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(sellerPayout.balance, 1 ether);
        assertEq(address(this).balance, protocolBefore + 2 ether);
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
    }

    function testRouterValueCannotExceedNativeFixedQuote() public {
        ICart.Listing memory listing =
            _listing(keccak256("router-value-bound"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"0b", 2 ether);
        router.configureMulti(new address[](0), new uint256[](0));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("router-value-bound", lines, route, actions, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);
        assertEq(router.executeCalls(), 0);
    }

    function testErc20PaymentRejectsRouterValue() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        ICart.Listing memory listing =
            _listing(keccak256("erc20-router-value"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("erc20-router-value", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: 0}(order, lines, listings, authorization, route, actions, signature);
    }

    function testErc20PaymentRejectsMsgValue() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        ICart.Listing memory listing =
            _listing(keccak256("erc20-msg-value"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(bytes(""), 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _erc20Order("erc20-msg-value", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);
    }

    function testRouterReceivesExactlySignedRouterValue() public {
        ICart.Listing memory listing =
            _listing(keccak256("router-value-forwarded"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.minimumUnitPrice = 0.6 ether;
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 0.6 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"0b", 0.4 ether);
        router.configureMulti(new address[](0), new uint256[](0));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("router-value-forwarded", lines, route, actions, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(router.lastRouterValue(), 0.4 ether);
        assertEq(sellerPayout.balance, 0.6 ether);
    }

    function testMalformedOpaqueInputReachesRouterBoundary() public {
        ICart.Listing memory listing =
            _listing(keccak256("malformed-router-input"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"09", 0);
        route.inputs[0] = hex"00";
        router.configureRevert(true);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("malformed-router-input", lines, route, actions, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        bytes memory routerReason = abi.encodeWithSignature("Error(string)", "router reverted");
        vm.expectRevert(
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, routerReason)
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);

        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testIncidentalUniversalRouterEthBalanceDoesNotBlockSettlement() public {
        vm.deal(address(router), 3 ether);
        ICart.Listing memory listing =
            _listing(keccak256("router-eth-retention"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"0b", 0);
        router.configureMulti(_tokens(address(0)), _amounts(1 ether));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderWithRoute("router-eth-retention", lines, route, actions, 1 ether);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(order, lines, listings, authorization, route, actions, signature);

        assertEq(address(router).balance, 2 ether);
        assertEq(sellerPayout.balance, 1 ether);
        assertEq(address(cart).balance, 0);
    }

    function testPaymentApprovalEqualsFixedQuoteAndIsRevoked() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        ICart.Listing memory listing =
            _listing(keccak256("approval-fixed-quote"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 0);
        router.configure(address(outputToken), 1 ether, 0, false);
        router.configureApprovalObservation(address(permit2), address(paymentToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("approval-fixed-quote", paymentToken, lines, route, 2 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 2 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 2 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(router.observedCartAllowance(), 2 ether);
        assertEq(router.observedPermit2Allowance(), 2 ether);
        assertEq(paymentToken.allowance(address(cart), address(permit2)), 0);
        (uint160 amount,,) = permit2.allowance(address(cart), address(paymentToken), address(router));
        assertEq(amount, 0);
        assertEq(paymentToken.allowance(address(cart), address(outputToken)), 0);
    }

    function testPreexistingPaymentApprovalsAreNotOverwritten() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        ICart.Listing memory listing =
            _listing(keccak256("preexisting-approval"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("preexisting-approval", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.prank(address(cart));
        paymentToken.approve(address(permit2), 2 ether);
        vm.prank(address(cart));
        permit2.approve(address(paymentToken), address(router), 1 ether, uint48(block.timestamp + 1 days));

        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.PreexistingAllowance.selector, address(paymentToken), address(permit2), 2 ether
            )
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(paymentToken.allowance(address(cart), address(permit2)), 2 ether);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(paymentToken), address(router));
        assertEq(permitAmount, 1 ether);
        assertEq(paymentToken.balanceOf(payer), 1 ether);
    }

    function testProtocolSpreadTransferFailureRevertsPurchase() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestRevertingTransferToken outputToken = new CartTestRevertingTransferToken();
        outputToken.setRejectingRecipient(address(this));
        ICart.Listing memory listing =
            _listing(keccak256("spread-transfer-failure"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 0);
        router.configure(address(outputToken), 1.1 ether, 0, false);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("spread-transfer-failure", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "rejected recipient"));
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(paymentToken.balanceOf(payer), 1 ether);
        assertEq(outputToken.balanceOf(sellerPayout), 0);
        assertEq(outputToken.balanceOf(address(cart)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testAllowanceRevokedBeforeFulfillment() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        CartTestERC721 nft = new CartTestERC721();
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(cart), true);
        CartAllowanceObserver observer =
            new CartAllowanceObserver(address(cart), address(paymentToken), address(permit2), address(router));
        ICart.Listing memory listing = _listing(
            keccak256("approval-before-fulfillment"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(nft),
            1,
            sellerPayout
        );
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: address(observer)});
        ICart.PayoutRoute memory route = _opaqueRoute(hex"08", 0);
        router.configure(address(outputToken), 1 ether, 0, false);
        ICart.PurchaseOrder memory order =
            _erc20Order("approval-before-fulfillment", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(observer.observedCartAllowance(), 0);
        assertEq(observer.observedPermit2Allowance(), 0);
    }

    function testFeeOnTransferPaymentRejected() public {
        CartTestFeeOnTransferToken paymentToken = new CartTestFeeOnTransferToken();
        ICart.Listing memory listing =
            _listing(keccak256("fee-on-transfer"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _opaqueRoute(bytes(""), 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _erc20Order("fee-on-transfer", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector,
                0,
                ICart.FailureStage.FUNDING,
                abi.encode(1 ether, 1 ether - 1)
            )
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testAllowancesClearWhenRouterReverts() public {
        CartTestToken paymentToken = new CartTestToken("Payment", "PAY");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");
        ICart.Listing memory listing =
            _listing(keccak256("router-revert-allowances"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route = _opaqueRoute(hex"10", 0);
        router.configureRevert(true);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order =
            _erc20Order("router-revert-allowances", paymentToken, lines, route, 1 ether, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        paymentToken.mint(payer, 1 ether);
        vm.prank(payer);
        paymentToken.approve(address(cart), 1 ether);

        bytes memory routerReason = abi.encodeWithSignature("Error(string)", "router reverted");
        vm.expectRevert(
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, routerReason)
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);

        assertEq(paymentToken.balanceOf(payer), 1 ether);
        assertEq(paymentToken.allowance(address(cart), address(permit2)), 0);
        (uint160 amount,,) = permit2.allowance(address(cart), address(paymentToken), address(router));
        assertEq(amount, 0);
    }

    function _opaqueRoute(bytes memory command, uint256 routerValue)
        internal
        pure
        returns (ICart.PayoutRoute memory route)
    {
        route.commands = command;
        route.inputs = new bytes[](command.length);
        route.routerValue = routerValue;
    }

    function _orderWithRoute(
        string memory id,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        ICart.FulfillmentAction[] memory actions,
        uint256 paymentAmount
    ) internal view returns (ICart.PurchaseOrder memory order) {
        order = ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(0),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
    }

    function _erc20Order(
        string memory id,
        IERC20 paymentToken,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        uint256 paymentAmount,
        ICart.FulfillmentAction[] memory actions
    ) internal view returns (ICart.PurchaseOrder memory order) {
        order = ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(paymentToken),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
    }

    function _tokens(address first, address second) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first;
        values[1] = second;
    }

    function _tokens(address only) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = only;
    }

    function _amounts(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = first;
        values[1] = second;
    }

    function _amounts(uint256 only) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = only;
    }

    function _recipients(address only) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = only;
    }
}
