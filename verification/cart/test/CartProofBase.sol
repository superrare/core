// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Cart} from "cart-src/Cart.sol";
import {CartHashes} from "cart-src/CartHashes.sol";
import {CartPayments} from "cart-src/CartPayments.sol";
import {CartRoutePolicy} from "cart-src/CartRoutePolicy.sol";
import {ICart} from "cart-src/ICart.sol";
import {
    CartProofSigner,
    CartProofToken,
    CartProofWETH,
    CartProofPermit2,
    CartProofRouter
} from "./mocks/CartProofModels.sol";

/// @dev Actual Cart proxy and payment delegatecalls; standard dependency models and assumed signatures.
abstract contract CartProofBase is Test {
    Cart internal cart;
    CartHashes internal hashes;
    CartRoutePolicy internal policy;
    CartProofWETH internal weth;
    CartProofPermit2 internal permit2;
    CartProofRouter internal router;
    CartProofToken internal payment;
    CartProofToken internal output;
    address internal constant PAYEE = address(0x5001);

    function setUp() public virtual {
        vm.assume(block.timestamp <= type(uint48).max - 1 days);
        policy = new CartRoutePolicy();
        weth = new CartProofWETH();
        permit2 = new CartProofPermit2();
        router = new CartProofRouter();
        payment = new CartProofToken();
        output = new CartProofToken();
        hashes = new CartHashes();
        CartPayments executor = new CartPayments(address(policy));
        Cart implementation = new Cart(address(policy), address(executor));
        cart = Cart(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            Cart.initialize,
                            (
                                address(this),
                                address(new CartProofSigner()),
                                address(router),
                                address(permit2),
                                address(weth)
                            )
                        )
                    )
                ))
        );
    }

    function _line(address currency, uint256 amount) internal pure returns (ICart.OrderLine memory) {
        return ICart.OrderLine({
            sku: bytes32(uint256(1)),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: currency,
            amount: amount,
            paymentRecipient: PAYEE
        });
    }

    function _execute(address currency, uint256 quote, ICart.OrderLine[] memory lines, ICart.PayoutRoute memory route)
        internal
        returns (bool)
    {
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = ICart.PurchaseOrder({
            orderId: bytes32(uint256(1)),
            paymentCurrency: currency,
            paymentAmount: quote,
            spreadRecipient: address(this),
            deadline: block.timestamp + 1 days,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
        ICart.ListingPurchaseAuthorization memory authorization;
        return _executeOrder(order, lines, new ICart.Listing[](0), authorization, route, actions);
    }

    function _executeOrder(
        ICart.PurchaseOrder memory order,
        ICart.OrderLine[] memory lines,
        ICart.Listing[] memory listings,
        ICart.ListingPurchaseAuthorization memory authorization,
        ICart.PayoutRoute memory route,
        ICart.FulfillmentAction[] memory actions
    ) internal returns (bool success) {
        (success,) = address(cart).call{value: order.paymentCurrency == address(0) ? order.paymentAmount : 0}(
            abi.encodeCall(Cart.executePurchase, (order, lines, listings, authorization, route, actions, bytes("")))
        );
    }
    receive() external payable {}
}
