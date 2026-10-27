// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Cart} from "../../../cart/Cart.sol";
import {CartHashes} from "../../../cart/CartHashes.sol";
import {CartPayments} from "../../../cart/CartPayments.sol";
import {CartRoutePolicy} from "../../../cart/CartRoutePolicy.sol";
import {ICart} from "../../../cart/ICart.sol";
import {CartTestPermit2, CartTestRouter, CartTestToken, CartTestWETH} from "../Cart.t.sol";

/// @dev Authorization is assumed for this settlement-tool assessment. This does not test signatures.
contract CartAssessmentSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice Small, explicitly bounded checks for assessing symbolic-tool compatibility.
/// @dev No listings, fulfillment, arbitrary callbacks, real router, or upgrade transition is covered.
contract CartToolAssessment is Test {
    Cart internal cart;
    CartHashes internal hashes;
    CartRoutePolicy internal policy;
    CartTestWETH internal weth;
    CartTestPermit2 internal permit2;
    CartTestRouter internal router;
    CartTestToken internal payment;
    CartTestToken internal output;

    address internal constant PAYEE = address(0x5001);

    function setUp() public {
        policy = new CartRoutePolicy();
        weth = new CartTestWETH();
        permit2 = new CartTestPermit2();
        router = new CartTestRouter();
        payment = new CartTestToken("Assessment payment", "PAY");
        output = new CartTestToken("Assessment output", "OUT");
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
                                address(new CartAssessmentSigner()),
                                address(router),
                                address(permit2),
                                address(weth)
                            )
                        )
                    )
                ))
        );
    }

    function check_singleCommandPolicy(uint8 command) public {
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(command);
        bytes[] memory inputs = new bytes[](1);
        (bool success,) = address(policy).call(abi.encodeCall(CartRoutePolicy.validate, (commands, inputs)));
        bool allowed = command == 0x00 || command == 0x01 || command == 0x02 || command == 0x04 || command == 0x08
            || command == 0x09 || command == 0x0b || command == 0x0c || command == 0x10;
        assert(success == allowed);
    }

    function check_nativeGroupedPayout(uint96 first, uint96 second, uint96 spread, uint96 baseline) public {
        _nativeGroupedPayout(first, second, spread, baseline, false);
    }

    /// @dev Run explicitly with --function canary_. Expected to fail on the wrong payout assertion.
    function canary_wrongNativePayout(uint96 first, uint96 second, uint96 spread, uint96 baseline) public {
        _nativeGroupedPayout(first, second, spread, baseline, true);
    }

    function _nativeGroupedPayout(uint96 first, uint96 second, uint96 spread, uint96 baseline, bool wrong) private {
        vm.assume(first > 0 && second > 0);
        uint256 obligation = uint256(first) + second;
        uint256 quote = obligation + spread;
        vm.deal(address(cart), baseline);
        weth.mint(address(cart), baseline);
        vm.deal(PAYEE, 0);
        vm.deal(address(this), quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _line(address(0), first);
        lines[1] = _line(address(0), second);
        ICart.PayoutRoute memory route;
        bool success = _execute(address(0), quote, lines, route);
        assert(success);
        assert(PAYEE.balance == obligation + (wrong ? 1 : 0));
        assert(address(this).balance == spread);
        assert(address(cart).balance == baseline);
        assert(weth.balanceOf(address(cart)) == baseline);
        assert(cart.executedOrderIds(bytes32(uint256(1))));
    }

    function check_erc20RouteApprovals(uint96 amount, uint96 spread, uint96 quote, uint96 baseline) public {
        vm.assume(amount > 0 && quote > 0);
        payment.mint(address(this), quote);
        payment.mint(address(cart), baseline);
        output.mint(address(cart), baseline);
        output.mint(address(router), uint256(amount) + spread);
        payment.approve(address(cart), quote);
        router.configureSettlement(
            address(permit2), address(0x6001), address(payment), address(output), quote, uint256(amount) + spread
        );
        router.configureApprovalObservation(address(permit2), address(payment));
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(address(output), amount);
        address[] memory path = new address[](2);
        path[0] = address(payment);
        path[1] = address(output);
        ICart.PayoutRoute memory route;
        route.commands = hex"09";
        route.inputs = new bytes[](1);
        route.inputs[0] = abi.encode(address(1), uint256(amount) + spread, quote, path, true);
        bool success = _execute(address(payment), quote, lines, route);
        assert(success);
        assert(payment.balanceOf(address(cart)) == baseline);
        assert(output.balanceOf(address(cart)) == baseline);
        assert(output.balanceOf(PAYEE) == amount);
        assert(output.balanceOf(address(this)) == spread);
        assert(payment.balanceOf(address(0x6001)) == quote);
        assert(router.observedCartAllowance() == quote);
        assert(router.observedPermit2Allowance() == quote);
        assert(payment.allowance(address(cart), address(permit2)) == 0);
        (uint160 approved,,) = permit2.allowance(address(cart), address(payment), address(router));
        assert(approved == 0);
    }

    function testConcreteNativeWitness() public {
        check_nativeGroupedPayout(1 ether, 2 ether, 0.25 ether, 0.5 ether);
    }

    function testConcreteErc20Witness() public {
        check_erc20RouteApprovals(2 ether, 0.25 ether, 3 ether, 0.5 ether);
    }

    function _line(address currency, uint256 amount) private pure returns (ICart.OrderLine memory) {
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
        private
        returns (bool success)
    {
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = ICart.PurchaseOrder({
            orderId: bytes32(uint256(1)),
            paymentCurrency: currency,
            paymentAmount: quote,
            deadline: block.timestamp + 1 days,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
        ICart.ListingPurchaseAuthorization memory authorization;
        (success,) = address(cart).call{value: currency == address(0) ? quote : 0}(
            abi.encodeCall(
                Cart.executePurchase, (order, lines, new ICart.Listing[](0), authorization, route, actions, bytes(""))
            )
        );
    }

    receive() external payable {}
}
