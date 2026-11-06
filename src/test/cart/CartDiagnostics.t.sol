// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "./CartFixture.sol";
import {CartTestToken, CartTestERC1155} from "./CartMocks.sol";
import {Cart} from "../../cart/Cart.sol";
import {ICart} from "../../cart/ICart.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CartSizedRevertRecipient {
    uint256 private immutable SIZE;

    constructor(uint256 size) {
        SIZE = size;
    }

    receive() external payable {
        bytes memory reason = new bytes(SIZE);
        if (SIZE != 0) {
            reason[0] = 0x42;
            reason[SIZE - 1] = 0x99;
        }
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }
}

// Funding remains exact. Only the selected outbound payment loses one unit.
contract CartDiagnosticTaxToken is CartTestToken {
    address private immutable TAXED_RECIPIENT;

    constructor(address recipient) CartTestToken("Diagnostic", "DIAG") {
        TAXED_RECIPIENT = recipient;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (to == TAXED_RECIPIENT && amount != 0) {
            _burn(from, 1);
            super._transfer(from, to, amount - 1);
        } else {
            super._transfer(from, to, amount);
        }
    }
}

contract CartDiagnosticsTest is CartFixture {
    function testProxyInitializationRejectsZeroOwner() public {
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory init = abi.encodeCall(
            Cart.initialize, (address(0), platformSigner, address(router), address(permit2), address(weth))
        );
        vm.expectRevert(ICart.InvalidOwner.selector);
        new ERC1967Proxy(address(implementation), init);
    }

    function testProxyInitializationAcceptsConfiguredOwner() public {
        assertEq(cart.owner(), address(this));
    }

    function testNativeFailureReasonBoundaries() public {
        uint256[6] memory sizes = [uint256(0), 31, 2047, 2048, 2049, 65_536];
        for (uint256 i; i < sizes.length; ++i) {
            _nativeFailure(sizes[i], false);
            _nativeFailure(sizes[i], true);
        }
    }

    function testFuzzNativeFailureReasonIsBounded(uint16 size, bool spread) public {
        _nativeFailure(size, spread);
    }

    function _nativeFailure(uint256 size, bool spread) private {
        address recipient = address(new CartSizedRevertRecipient(size));
        ICart.Listing memory listing = _listing(
            keccak256(abi.encode(size, spread)),
            ICart.FulfillmentKind.OFF_CHAIN,
            address(0),
            0,
            spread ? sellerPayout : recipient
        );
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("native-diagnostics", lines, route, actions);
        order.paymentAmount = 2 ether;
        order.spreadRecipient = spread ? recipient : collector;
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        vm.deal(payer, 2 ether);
        vm.deal(address(cart), 3 ether);
        bytes memory expectedReason = new bytes(size > 2048 ? 2048 : size);
        if (size != 0) {
            expectedReason[0] = 0x42;
            if (size <= 2048) expectedReason[size - 1] = 0x99;
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector,
                0,
                spread ? ICart.FailureStage.SPREAD : ICart.FailureStage.PAYOUT,
                expectedReason
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(order, lines, listings, authorization, route, actions, signature);
        assertEq(payer.balance, 2 ether);
        assertEq(address(cart).balance, 3 ether);
        assertEq(sellerPayout.balance, 0);
        assertEq(recipient.balance, 0);
        assertEq(collector.balance, 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testErc20PayoutMismatchReportsPayoutStage() public {
        _tokenMismatch(false);
    }

    function testErc20SpreadMismatchReportsSpreadStage() public {
        _tokenMismatch(true);
    }

    function _tokenMismatch(bool spread) private {
        CartDiagnosticTaxToken token = new CartDiagnosticTaxToken(spread ? collector : sellerPayout);
        ICart.Listing memory listing =
            _listing(keccak256("token-diagnostics"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(token);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(token);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _orderSingle("token-diagnostics", token, lines, route, 2 ether);
        order.spreadRecipient = collector;
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        token.mint(payer, 2 ether);
        token.mint(address(cart), 3 ether);
        vm.prank(payer);
        token.approve(address(cart), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector,
                0,
                spread ? ICart.FailureStage.SPREAD : ICart.FailureStage.PAYOUT,
                abi.encode(1 ether, 1 ether - 1)
            )
        );
        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, actions, signature);
        assertEq(token.balanceOf(payer), 2 ether);
        assertEq(token.balanceOf(address(cart)), 3 ether);
        assertEq(token.balanceOf(sellerPayout), 0);
        assertEq(token.balanceOf(collector), 0);
        assertEq(token.allowance(payer, address(cart)), 2 ether);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testCoverageErrorUsesLineIndexWithoutAnAction() public {
        CartTestERC1155 token = new CartTestERC1155();
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("second-line"), ICart.FulfillmentKind.ERC1155_TRANSFER, address(token), 42, sellerPayout, 2
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine(
            keccak256("fee"), bytes32(0), ICart.FulfillmentKind.NONE, 1, address(0), 1 ether, collector
        );
        lines[1] = _lineForListing(listing, 2, 2 ether)[0];
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("second-line", lines, route, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidFulfillmentCoverage.selector, 1, 2, 0));
        vm.prank(payer);
        cart.executePurchase{value: 3 ether}(order, lines, listings, authorization, route, actions, signature);
        assertEq(payer.balance, 3 ether);
        assertEq(collector.balance, 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testCoverageReportsActualAndExpectedQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 3);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("coverage-diagnostics"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            3
        );
        for (uint256 quantity; quantity <= 3; ++quantity) {
            if (quantity == 2) continue;
            ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](quantity == 0 ? 0 : 1);
            if (quantity != 0) actions[0] = ICart.FulfillmentAction(0, quantity, collector);
            _executeNativeListingExpectRevert(
                listing,
                "coverage-diagnostics",
                2,
                actions,
                abi.encodeWithSelector(ICart.InvalidFulfillmentCoverage.selector, 0, 2, quantity)
            );
            assertEq(token.balanceOf(seller, 42), 3);
            assertEq(token.balanceOf(collector, 42), 0);
            assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        }
    }
}
