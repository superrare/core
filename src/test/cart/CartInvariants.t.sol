// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Cart} from "../../cart/Cart.sol";
import {CartHashes} from "../../cart/CartHashes.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartTestPermit2, CartTestRouter, CartTestToken, CartTestWETH} from "./Cart.t.sol";

contract CartInvariantProtocolSink {
    receive() external payable {}
}

/// @notice Stateful custody invariants for repeated successful opaque-route purchases.
/// @dev The handler deliberately uses the same fixed-quote route boundary as clients while the
/// mock Router supplies deterministic outputs. Real Router byte encodings are covered separately
/// by the opt-in Ethereum fork suite.
contract CartInvariantsTest is Test {
    uint256 private constant PLATFORM_PK = 0xB0B;

    Cart internal cart;
    CartHashes internal hashes;
    CartTestWETH internal weth;
    CartTestPermit2 internal permit2;
    CartTestRouter internal router;
    CartTestToken internal paymentToken;
    CartTestToken internal outputToken;
    CartInvariantProtocolSink internal protocolSink;

    uint256 internal nativeBaseline;
    uint256 internal wethBaseline;
    uint256 internal paymentBaseline;
    uint256 internal outputBaseline;
    uint256 internal nonce;

    function setUp() public {
        weth = new CartTestWETH();
        permit2 = new CartTestPermit2();
        router = new CartTestRouter();
        paymentToken = new CartTestToken("Invariant Payment", "IPAY");
        outputToken = new CartTestToken("Invariant Output", "IOUT");

        CartRoutePolicy routePolicy = new CartRoutePolicy();
        CartPayments paymentExecutor = new CartPayments(address(routePolicy));
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData = abi.encodeCall(
            Cart.initialize, (address(this), vm.addr(PLATFORM_PK), address(router), address(permit2), address(weth))
        );
        cart = Cart(payable(address(new ERC1967Proxy(address(implementation), initData))));
        hashes = new CartHashes();
        protocolSink = new CartInvariantProtocolSink();
        cart.setProtocolRecipient(address(protocolSink));

        vm.deal(address(cart), 0.25 ether);
        weth.mint(address(cart), 0.5 ether);
        paymentToken.mint(address(cart), 1 ether);
        outputToken.mint(address(cart), 2 ether);
        nativeBaseline = address(cart).balance;
        wethBaseline = weth.balanceOf(address(cart));
        paymentBaseline = paymentToken.balanceOf(address(cart));
        outputBaseline = outputToken.balanceOf(address(cart));

        targetContract(address(this));
    }

    /// @dev Repeated native fixed-quote routes must leave Cart at its original baselines.
    function stepNative(uint96 rawQuote, uint96 rawOutput) external {
        uint256 quote = bound(uint256(rawQuote), 1e12, 1 ether);
        uint256 obligation = bound(uint256(rawOutput), 1, 1 ether);
        uint256 surplus = uint256(rawOutput) % 1e6 + 1;
        router.configure(address(outputToken), obligation + surplus, 0, false);
        vm.deal(address(this), quote);

        ICart.PayoutRoute memory route = _route(quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(obligation, address(0x5001), "native");
        uint256 recipientBefore = outputToken.balanceOf(address(0x5001));
        uint256 protocolBefore = outputToken.balanceOf(address(protocolSink));
        uint256 buyerBefore = address(this).balance;
        _execute(keccak256(abi.encode("native", nonce++)), address(0), quote, lines, route);
        assertEq(outputToken.balanceOf(address(0x5001)), recipientBefore + obligation);
        assertEq(outputToken.balanceOf(address(protocolSink)), protocolBefore + surplus);
        assertLe(buyerBefore - address(this).balance, quote);
    }

    /// @dev ERC-20 fixed-quote routes must clear both approval layers after every execution.
    function stepErc20(uint96 rawQuote, uint96 rawOutput) external {
        uint256 quote = bound(uint256(rawQuote), 1e12, 1 ether);
        uint256 obligation = bound(uint256(rawOutput), 1, 1 ether);
        uint256 surplus = uint256(rawOutput) % 1e6 + 1;
        router.configure(address(outputToken), obligation + surplus, 0, false);
        paymentToken.mint(address(this), quote);
        vm.prank(address(this));
        paymentToken.approve(address(cart), quote);

        ICart.PayoutRoute memory route = _route(0);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(obligation, address(0x5002), "erc20");
        uint256 recipientBefore = outputToken.balanceOf(address(0x5002));
        uint256 protocolOutputBefore = outputToken.balanceOf(address(protocolSink));
        uint256 protocolPaymentBefore = paymentToken.balanceOf(address(protocolSink));
        uint256 buyerBefore = paymentToken.balanceOf(address(this));
        _execute(keccak256(abi.encode("erc20", nonce++)), address(paymentToken), quote, lines, route);
        assertEq(outputToken.balanceOf(address(0x5002)), recipientBefore + obligation);
        assertEq(outputToken.balanceOf(address(protocolSink)), protocolOutputBefore + surplus);
        assertEq(paymentToken.balanceOf(address(protocolSink)), protocolPaymentBefore + quote);
        assertLe(buyerBefore - paymentToken.balanceOf(address(this)), quote);
    }

    /// @dev A native line may be funded by positive WETH output, but the WETH baseline is retained.
    function stepNativeFamily(uint96 rawAmount) external {
        uint256 obligation = bound(uint256(rawAmount), 1e12, 1 ether);
        uint256 surplus = uint256(rawAmount) % 1e6 + 1;
        uint256 returned = obligation + surplus;
        uint256 quote = obligation + 1e12;
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = returned;
        router.configureMulti(tokens, amounts);
        vm.deal(address(weth), returned);
        vm.deal(address(this), quote);

        ICart.PayoutRoute memory route = _route(quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _nativeLine(obligation, address(0x5003), "native-family");
        uint256 recipientBefore = address(0x5003).balance;
        uint256 protocolBefore = weth.balanceOf(address(protocolSink));
        _execute(keccak256(abi.encode("native-family", nonce++)), address(0), quote, lines, route);
        assertEq(address(0x5003).balance, recipientBefore + obligation);
        assertEq(weth.balanceOf(address(protocolSink)), protocolBefore + surplus);
    }

    function invariant_supportedCartBalancesReturnToBaselines() public {
        assertEq(address(cart).balance, nativeBaseline);
        assertEq(weth.balanceOf(address(cart)), wethBaseline);
        assertEq(paymentToken.balanceOf(address(cart)), paymentBaseline);
        assertEq(outputToken.balanceOf(address(cart)), outputBaseline);
    }

    function invariant_paymentApprovalsAreCleared() public {
        assertEq(paymentToken.allowance(address(cart), address(permit2)), 0);
        (uint160 amount,,) = permit2.allowance(address(cart), address(paymentToken), address(router));
        assertEq(amount, 0);
    }

    function _execute(
        bytes32 orderId,
        address paymentCurrency,
        uint256 quote,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route
    ) private {
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = ICart.PurchaseOrder({
            orderId: orderId,
            paymentCurrency: paymentCurrency,
            deadline: block.timestamp + 1 days,
            paymentAmount: quote,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
        ICart.ListingPurchaseAuthorization memory authorization;
        bytes memory signature = _sign(hashes.hashOrder(cart.DOMAIN_SEPARATOR(), order));
        if (paymentCurrency == address(0)) {
            cart.executePurchase{value: quote}(
                order, lines, new ICart.Listing[](0), authorization, route, actions, signature
            );
        } else {
            cart.executePurchase(order, lines, new ICart.Listing[](0), authorization, route, actions, signature);
        }
    }

    function _route(uint256 routerValue) private pure returns (ICart.PayoutRoute memory route) {
        route.commands = hex"08";
        route.inputs = new bytes[](1);
        route.inputs[0] = bytes("opaque");
        route.routerValue = routerValue;
    }

    function _line(uint256 amount, address recipient, string memory id)
        private
        view
        returns (ICart.OrderLine memory line)
    {
        return _lineWithKind(amount, recipient, id, ICart.FulfillmentKind.CURRENCY_SWAP, address(outputToken));
    }

    function _nativeLine(uint256 amount, address recipient, string memory id)
        private
        pure
        returns (ICart.OrderLine memory line)
    {
        return _lineWithKind(amount, recipient, id, ICart.FulfillmentKind.NONE, address(0));
    }

    function _lineWithKind(
        uint256 amount,
        address recipient,
        string memory id,
        ICart.FulfillmentKind kind,
        address currency
    ) private pure returns (ICart.OrderLine memory line) {
        line = ICart.OrderLine({
            sku: keccak256(bytes(id)),
            listingDigest: bytes32(0),
            fulfillmentKind: kind,
            quantity: 1,
            settlementCurrency: currency,
            amount: amount,
            paymentRecipient: recipient
        });
    }

    function _sign(bytes32 digest) private returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PLATFORM_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}
