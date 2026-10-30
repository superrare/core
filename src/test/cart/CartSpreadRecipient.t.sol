// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "./CartFixture.sol";
import {CartTestToken, RevertingPayoutRecipient} from "./CartMocks.sol";
import {ICart} from "../../cart/ICart.sol";

/// @notice The signed checkout owns the destination of every supported surplus currency.
contract CartSpreadRecipientTest is CartFixture {
    function testSpreadRecipientIsIncludedInCanonicalOrderHash() public {
        (ICart.PurchaseOrder memory order,,,) = _nativeCheckout("canonical");
        // Encode the external typed-data schema independently of Cart's hashing implementation.
        bytes32 typeHash = keccak256(
            "PurchaseOrder(bytes32 orderId,address paymentCurrency,uint256 deadline,uint256 paymentAmount,address spreadRecipient,bytes32 orderLinesHash,bytes32 payoutRouteHash,bytes32 fulfillmentActionsHash)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                order.orderId,
                order.paymentCurrency,
                order.deadline,
                order.paymentAmount,
                order.spreadRecipient,
                order.orderLinesHash,
                order.payoutRouteHash,
                order.fulfillmentActionsHash
            )
        );
        assertEq(_orderDigest(order), keccak256(abi.encodePacked("\x19\x01", cart.DOMAIN_SEPARATOR(), structHash)));
    }

    function testChangingSpreadRecipientInvalidatesPlatformSignature() public {
        (
            ICart.PurchaseOrder memory order,
            ICart.OrderLine[] memory lines,
            ICart.PayoutRoute memory route,
            ICart.FulfillmentAction[] memory actions
        ) = _nativeCheckout("tamper");
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        order.spreadRecipient = collector;
        vm.deal(payer, order.paymentAmount);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(order)));
        _executeNative(order, lines, route, actions, signature);
        assertFalse(cart.executedOrderIds(order.orderId));
        assertEq(sellerPayout.balance, 0);
    }

    function testLegacyOrderSignatureCannotAuthorizeNewCheckout() public {
        (
            ICart.PurchaseOrder memory order,
            ICart.OrderLine[] memory lines,
            ICart.PayoutRoute memory route,
            ICart.FulfillmentAction[] memory actions
        ) = _nativeCheckout("legacy-signature");
        // Reconstruct the old struct so upgrading cannot silently reuse an unsigned destination.
        bytes32 oldStructHash = keccak256(
            abi.encode(
                keccak256(
                    "PurchaseOrder(bytes32 orderId,address paymentCurrency,uint256 deadline,uint256 paymentAmount,bytes32 orderLinesHash,bytes32 payoutRouteHash,bytes32 fulfillmentActionsHash)"
                ),
                order.orderId,
                order.paymentCurrency,
                order.deadline,
                order.paymentAmount,
                order.orderLinesHash,
                order.payoutRouteHash,
                order.fulfillmentActionsHash
            )
        );
        bytes32 oldDigest = keccak256(abi.encodePacked("\x19\x01", cart.DOMAIN_SEPARATOR(), oldStructHash));
        vm.deal(payer, order.paymentAmount);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(order)));
        _executeNative(order, lines, route, actions, _sign(PLATFORM_PK, oldDigest));
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testZeroSpreadRecipientRejectedEvenWithoutSurplus() public {
        (
            ICart.PurchaseOrder memory order,
            ICart.OrderLine[] memory lines,
            ICart.PayoutRoute memory route,
            ICart.FulfillmentAction[] memory actions
        ) = _nativeCheckout("zero-recipient");
        order.spreadRecipient = address(0);
        order.paymentAmount = lines[0].amount;
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, order.paymentAmount);
        vm.expectRevert(ICart.InvalidSpreadRecipient.selector);
        _executeNative(order, lines, route, actions, signature);
        assertFalse(cart.executedOrderIds(order.orderId));
        assertEq(payer.balance, order.paymentAmount);
    }

    function testConsecutiveNativeCheckoutsUseTheirOwnSignedRecipients() public {
        // An upgraded proxy may retain its old global recipient, which must have no effect.
        bytes32 retiredSlot = bytes32(uint256(0xc012b0fbebfe5af5b8d952297ba0e80136c8473aa49759c18a1edebf3f3a9b00) + 4);
        vm.store(address(cart), retiredSlot, bytes32(uint256(uint160(address(0x7003)))));
        vm.deal(address(cart), 3 ether);
        for (uint256 i; i < 2; ++i) {
            (
                ICart.PurchaseOrder memory order,
                ICart.OrderLine[] memory lines,
                ICart.PayoutRoute memory route,
                ICart.FulfillmentAction[] memory actions
            ) = _nativeCheckout(i == 0 ? "native-first" : "native-second");
            order.spreadRecipient = i == 0 ? address(0x7001) : address(0x7002);
            vm.deal(payer, order.paymentAmount);
            _executeNative(order, lines, route, actions, _sign(PLATFORM_PK, _orderDigest(order)));
            assertEq(order.spreadRecipient.balance, 0.25 ether);
            assertTrue(cart.executedOrderIds(order.orderId));
            assertEq(address(cart).balance, 3 ether);
        }
        assertEq(address(0x7001).balance, 0.25 ether);
        assertEq(address(0x7002).balance, 0.25 ether);
        assertEq(sellerPayout.balance, 2 ether);
        assertEq(address(0x7003).balance, 0);
        assertEq(vm.load(address(cart), retiredSlot), bytes32(uint256(uint160(address(0x7003)))));
    }

    function testConsecutiveRoutedCheckoutsSendInputAndOutputSpreadToSignedRecipient() public {
        CartTestToken input = new CartTestToken("Input", "IN");
        CartTestToken output = new CartTestToken("Output", "OUT");
        input.mint(address(cart), 3 ether);
        output.mint(address(cart), 4 ether);
        for (uint256 i; i < 2; ++i) {
            ICart.OrderLine[] memory lines = _feeLine(address(output));
            ICart.PayoutRoute memory route;
            route.commands = hex"08";
            route.inputs = new bytes[](1);
            route.inputs[0] = bytes("opaque");
            router.configure(address(output), 1.25 ether, 0, false);
            ICart.PurchaseOrder memory order =
                _orderSingle(i == 0 ? "token-first" : "token-second", input, lines, route, 2 ether);
            order.spreadRecipient = i == 0 ? address(0x7001) : address(0x7002);
            input.mint(payer, 2 ether);
            vm.prank(payer);
            input.approve(address(cart), 2 ether);
            bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
            ICart.ListingPurchaseAuthorization memory authorization;
            vm.prank(payer);
            cart.executePurchase(
                order, lines, new ICart.Listing[](0), authorization, route, new ICart.FulfillmentAction[](0), signature
            );
            // The mock router returns output without consuming input, so both deltas are spread.
            assertEq(input.balanceOf(order.spreadRecipient), 2 ether);
            assertEq(output.balanceOf(order.spreadRecipient), 0.25 ether);
            assertEq(input.balanceOf(address(cart)), 3 ether);
            assertEq(output.balanceOf(address(cart)), 4 ether);
            assertEq(input.allowance(address(cart), address(permit2)), 0);
        }
        assertEq(output.balanceOf(sellerPayout), 2 ether);
    }

    function testRejectingNativeSpreadRecipientRollsBackListingAndPayout() public {
        RevertingPayoutRecipient recipient = new RevertingPayoutRecipient();
        ICart.Listing memory listing =
            _listing(keccak256("reject-spread"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("reject-spread", lines, route, actions);
        order.paymentAmount = 1.25 ether;
        order.spreadRecipient = address(recipient);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, order.paymentAmount);
        vm.expectRevert(abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.SPREAD, bytes("")));
        vm.prank(payer);
        cart.executePurchase{value: order.paymentAmount}(
            order, lines, listings, authorization, route, actions, signature
        );
        assertEq(payer.balance, order.paymentAmount);
        assertEq(sellerPayout.balance, 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function _nativeCheckout(string memory id)
        private
        view
        returns (
            ICart.PurchaseOrder memory order,
            ICart.OrderLine[] memory lines,
            ICart.PayoutRoute memory route,
            ICart.FulfillmentAction[] memory actions
        )
    {
        lines = _feeLine(address(0));
        route = _emptyRoute();
        actions = new ICart.FulfillmentAction[](0);
        order = _order(id, lines, route, actions);
        order.paymentAmount = 1.25 ether;
        order.spreadRecipient = address(0x7001);
    }

    function _feeLine(address currency) private view returns (ICart.OrderLine[] memory lines) {
        lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: keccak256("fee"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: currency,
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
    }

    function _executeNative(
        ICart.PurchaseOrder memory order,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        ICart.FulfillmentAction[] memory actions,
        bytes memory signature
    ) private {
        ICart.ListingPurchaseAuthorization memory authorization;
        vm.prank(payer);
        cart.executePurchase{value: order.paymentAmount}(
            order, lines, new ICart.Listing[](0), authorization, route, actions, signature
        );
    }
}
