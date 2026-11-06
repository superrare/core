// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "./CartFixture.sol";
import {CartTestToken} from "./CartMocks.sol";
import {ICart} from "../../cart/ICart.sol";
import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";

/// @notice Checkout regressions for backend routing mistakes, including transaction rollback.
contract CartRouteProtectionTest is CartFixture {
    function testMissingNativeRefundRevertsAndRollsBack() public {
        router.configureRetainNative(true);
        router.configure(address(weth), 1 ether, 0, false);
        ICart.PayoutRoute memory route;
        route.commands = hex"0b";
        route.inputs = new bytes[](1);
        route.inputs[0] = abi.encode(address(2), 1 ether);
        route.routerValue = 1 ether;
        _reject(
            route,
            address(weth),
            abi.encodeWithSelector(ICartRoutePolicy.RouterBalanceIncreased.selector, address(0), 0, 1 ether)
        );
    }

    function testRetainedTokenRevertsAndRollsBack() public {
        router.configure(address(weth), 1 ether, 7, false);
        ICart.PayoutRoute memory route = _multiOutputRoute(address(weth), address(weth), address(0), 1 ether, 0, true);
        _reject(
            route,
            address(weth),
            abi.encodeWithSelector(ICartRoutePolicy.RouterBalanceIncreased.selector, address(weth), 0, 7)
        );
    }

    function testWrongRecipientRevertsBeforeRouterCall() public {
        ICart.PayoutRoute memory route;
        route.commands = hex"04";
        route.inputs = new bytes[](1);
        route.inputs[0] = abi.encode(address(0), address(0xbad), 0);
        route.routerValue = 0.1 ether;
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        address[] memory recipients = new address[](1);
        amounts[0] = 0.1 ether;
        recipients[0] = address(0xbad);
        router.configureMultiTo(tokens, amounts, recipients);
        // The quote funds the seller in full even if the extra 0.1 ETH is misdirected.
        _reject(
            route,
            address(0),
            abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0xbad))
        );
    }

    function _reject(ICart.PayoutRoute memory route, address currency, bytes memory reason) private {
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine("fee", 0, ICart.FulfillmentKind.NONE, 1, currency, 1 ether, sellerPayout);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("route-footgun", lines, route, actions);
        if (currency == address(0)) order.paymentAmount += route.routerValue;
        ICart.ListingPurchaseAuthorization memory auth;
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, order.paymentAmount);
        uint256 beforePayer = payer.balance;
        vm.expectRevert(abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, reason));
        vm.prank(payer);
        cart.executePurchase{value: order.paymentAmount}(order, lines, listings, auth, route, actions, signature);
        assertEq(payer.balance, beforePayer);
        assertEq(address(router).balance, 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(cart)), 0);
        assertEq(sellerPayout.balance, 0);
        assertEq(address(0xbad).balance, 0);
        assertEq(router.executeCalls(), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }
}
