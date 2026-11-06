// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "../../../cart/CartFixture.sol";
import {Cart, CartPayments, CartHashes, CartRoutePolicy, ICart} from "../../../cart/CartFixture.sol";
import {CartTestToken, CartTestWETH, CartTestRouter, CartTestPermit2} from "../../../cart/CartMocks.sol";
import {ICartRoutePolicy} from "../../../../cart/ICartRoutePolicy.sol";
import {CartLens} from "../../../../cart/CartLens.sol";
import {ICartLens} from "../../../../cart/ICartLens.sol";

/// @notice Signed checkout regressions for captured provider routes on a pinned Sepolia fork.
/// @dev All upgrades and signer changes are local fork state. No transactions are broadcast.
contract CartProviderRoutesSepoliaTest is CartFixture {
  uint256 private constant FORK_BLOCK = 12_078_702;
  address private constant PROXY = 0xACfF2622f53f360274df3014DC135EfDC058786B;
  address private constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
  address private constant RARE = 0x197FaeF3f59eC80113e773Bb6206a17d183F97CB;

  struct PathKey {
    address currency;
    uint24 fee;
    int24 spacing;
    address hooks;
    bytes hookData;
  }
  struct ExactOutput {
    address currencyOut;
    PathKey[] path;
    uint128 amountOut;
    uint128 amountInMaximum;
  }
  struct Checkout {
    ICart.PurchaseOrder order;
    ICart.OrderLine[] lines;
    ICart.Listing[] listings;
    ICart.ListingPurchaseAuthorization authorization;
    ICart.FulfillmentAction[] actions;
    bytes signature;
    bytes32 listingDigest;
  }

  function testCapturedV4SettleTakeCheckout() public {
    _candidate();
    ICart.PayoutRoute memory route = _captured(".v4");
    (, bytes[] memory params) = abi.decode(route.inputs[0], (bytes, bytes[]));
    ExactOutput memory swap = abi.decode(params[0], (ExactOutput));
    _successfulCheckout(route, USDC, RARE, swap.amountInMaximum, swap.amountOut, 1997);
  }

  function testCapturedV3RouterCustodyUnwrapCheckout() public {
    _candidate();
    ICart.PayoutRoute memory route = _captured(".v3");
    (, uint256 output, uint256 maximum, , ) = abi.decode(route.inputs[0], (address, uint256, uint256, bytes, bool));
    _successfulCheckout(route, RARE, address(0), maximum, output, 122085765400809294650);
  }

  function testV3TemporaryCustodyWithoutUnwrapRevertsAtomically() public {
    _candidate();
    ICart.PayoutRoute memory captured = _captured(".v3");
    (, uint256 output, uint256 maximum, , ) = abi.decode(captured.inputs[0], (address, uint256, uint256, bytes, bool));
    ICart.PayoutRoute memory route;
    route.commands = hex"01";
    route.inputs = new bytes[](1);
    route.inputs[0] = captured.inputs[0];
    uint256 beforeRouter = weth.balanceOf(address(router));
    Checkout memory checkout = _checkout(route, RARE, address(0), maximum, output);
    _rejectedCheckout(
      checkout,
      route,
      abi.encodeWithSelector(
        ICartRoutePolicy.RouterBalanceIncreased.selector,
        address(weth),
        beforeRouter,
        beforeRouter + output
      )
    );
  }

  function testV4CannotPayOrderRecipientDirectly() public {
    _candidate();
    ICart.PayoutRoute memory route = _captured(".v4");
    (bytes memory actions, bytes[] memory params) = abi.decode(route.inputs[0], (bytes, bytes[]));
    ExactOutput memory swap = abi.decode(params[0], (ExactOutput));
    params[2] = abi.encode(RARE, sellerPayout, swap.amountOut);
    route.inputs[0] = abi.encode(actions, params);
    Checkout memory checkout = _checkout(route, USDC, RARE, swap.amountInMaximum, swap.amountOut);
    _rejectedCheckout(
      checkout,
      route,
      abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, sellerPayout)
    );
  }

  function _candidate() private {
    // Select inside the test so the real router retains its Cancun execution context.
    vm.createSelectFork(vm.envString("ETH_SEPOLIA_RPC_URL"), FORK_BLOCK);
    assertEq(block.chainid, 11155111);
    cart = Cart(payable(PROXY));
    router = CartTestRouter(payable(cart.universalRouter()));
    permit2 = CartTestPermit2(cart.permit2());
    weth = CartTestWETH(cart.weth());
    hashes = new CartHashes();
    routePolicy = new CartRoutePolicy();
    paymentExecutor = new CartPayments(address(routePolicy));
    Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
    address owner = cart.owner();
    vm.prank(owner);
    cart.upgradeTo(address(implementation));
    platformSigner = vm.addr(PLATFORM_PK);
    vm.prank(owner);
    cart.setPlatformSigner(platformSigner);
    // Seed protected Cart custody, distinct from the payer's checkout funds.
    vm.deal(address(cart), 0.2 ether);
    deal(address(weth), address(cart), 37);
  }

  function _captured(string memory key) private view returns (ICart.PayoutRoute memory route) {
    string memory fixture = vm.readFile("src/test/fixtures/cart-provider-sepolia.json");
    route.commands = abi.decode(vm.parseJson(fixture, string.concat(key, ".commands")), (bytes));
    route.inputs = abi.decode(vm.parseJson(fixture, string.concat(key, ".inputs")), (bytes[]));
  }

  function _checkout(
    ICart.PayoutRoute memory route,
    address input,
    address output,
    uint256 maximum,
    uint256 amount
  ) private returns (Checkout memory checkout) {
    deal(input, payer, maximum);
    deal(input, address(cart), 19);
    if (output != address(0)) deal(output, address(cart), 29);
    vm.prank(payer);
    CartTestToken(input).approve(address(cart), maximum);
    ICart.Listing memory listing = _listing("provider-route", ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
    listing.settlementCurrency = output;
    listing.minimumUnitPrice = amount;
    checkout.listings = _singletonListing(listing);
    checkout.lines = _lineForListing(listing, 1, amount);
    checkout.lines[0].settlementCurrency = output;
    checkout.authorization = _rootAuthorization(checkout.listings, SELLER_PK);
    checkout.actions = new ICart.FulfillmentAction[](0);
    checkout.order = _order("provider-route-checkout", checkout.lines, route, checkout.actions);
    checkout.order.paymentCurrency = input;
    checkout.order.paymentAmount = maximum;
    checkout.order.spreadRecipient = collector;
    checkout.signature = _sign(PLATFORM_PK, _orderDigest(checkout.order));
    checkout.listingDigest = _listingDigest(listing);
  }

  function _execute(Checkout memory checkout, ICart.PayoutRoute memory route) private {
    vm.prank(payer);
    cart.executePurchase(
      checkout.order,
      checkout.lines,
      checkout.listings,
      checkout.authorization,
      route,
      checkout.actions,
      checkout.signature
    );
  }

  function _successfulCheckout(
    ICart.PayoutRoute memory route,
    address input,
    address output,
    uint256 maximum,
    uint256 amount,
    uint256 spent
  ) private {
    Checkout memory checkout = _checkout(route, input, output, maximum, amount);
    uint256 beforeRecipient = _balance(output, sellerPayout);
    uint256 beforeSpread = _balance(input, collector);
    uint256 beforeRouterInput = _balance(input, address(router));
    uint256 beforeRouterOutput = _balance(output, address(router));
    uint256 beforeRouterWeth = weth.balanceOf(address(router));
    uint256 beforeRouterNative = address(router).balance;
    ICartLens.RoutePreview memory preview = new CartLens().previewRoute(address(cart), route);
    assertTrue(preview.valid);
    _execute(checkout, route);
    assertEq(_balance(output, sellerPayout), beforeRecipient + amount);
    assertEq(_balance(input, collector), beforeSpread + maximum - spent);
    assertEq(_balance(input, payer), 0);
    assertEq(_balance(input, address(cart)), 19);
    if (output != address(0)) assertEq(_balance(output, address(cart)), 29);
    assertEq(address(cart).balance, 0.2 ether);
    assertEq(weth.balanceOf(address(cart)), 37);
    assertLe(_balance(input, address(router)), beforeRouterInput);
    assertLe(_balance(output, address(router)), beforeRouterOutput);
    assertLe(weth.balanceOf(address(router)), beforeRouterWeth);
    assertLe(address(router).balance, beforeRouterNative);
    assertTrue(cart.executedOrderIds(checkout.order.orderId));
    assertEq(cart.filledQuantity(checkout.listingDigest), 1);
    _clearedAllowances(input);
  }

  function _rejectedCheckout(Checkout memory checkout, ICart.PayoutRoute memory route, bytes memory reason) private {
    address input = checkout.order.paymentCurrency;
    uint256 beforeRecipient = _balance(checkout.lines[0].settlementCurrency, sellerPayout);
    uint256 beforeSpread = _balance(input, collector);
    uint256 beforeWeth = weth.balanceOf(address(router));
    uint256 beforeRouterInput = _balance(input, address(router));
    uint256 beforeRouterOutput = _balance(checkout.lines[0].settlementCurrency, address(router));
    uint256 beforeRouterNative = address(router).balance;
    vm.expectRevert(abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.ROUTING, reason));
    _execute(checkout, route);
    assertEq(_balance(input, payer), checkout.order.paymentAmount);
    assertEq(_balance(input, address(cart)), 19);
    assertEq(address(cart).balance, 0.2 ether);
    assertEq(weth.balanceOf(address(cart)), 37);
    assertEq(weth.balanceOf(address(router)), beforeWeth);
    assertEq(_balance(input, address(router)), beforeRouterInput);
    assertEq(_balance(checkout.lines[0].settlementCurrency, address(router)), beforeRouterOutput);
    assertEq(address(router).balance, beforeRouterNative);
    if (checkout.lines[0].settlementCurrency != address(0)) {
      assertEq(_balance(checkout.lines[0].settlementCurrency, address(cart)), 29);
    }
    assertEq(_balance(checkout.lines[0].settlementCurrency, sellerPayout), beforeRecipient);
    assertEq(_balance(input, collector), beforeSpread);
    assertFalse(cart.executedOrderIds(checkout.order.orderId));
    assertEq(cart.filledQuantity(checkout.listingDigest), 0);
    _clearedAllowances(input);
  }

  function _clearedAllowances(address input) private {
    assertEq(CartTestToken(input).allowance(address(cart), address(permit2)), 0);
    (uint160 amount, , ) = permit2.allowance(address(cart), input, address(router));
    assertEq(amount, 0);
  }

  function _balance(address token, address account) private view returns (uint256) {
    return token == address(0) ? account.balance : CartTestToken(token).balanceOf(account);
  }
}
