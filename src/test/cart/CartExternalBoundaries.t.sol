// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Cart} from "../../cart/Cart.sol";
import {CartLens} from "../../cart/CartLens.sol";
import {ICart} from "../../cart/ICart.sol";
import {ICartLens} from "../../cart/ICartLens.sol";
import {IPermit2Cart} from "../../cart/IPermit2Cart.sol";
import {CartFixture} from "./CartFixture.sol";
import {CartTestToken, CartTestWETH, CartTestERC721} from "./CartMocks.sol";

contract BoundaryMint is ERC721, Ownable {
  error MintRejected();
  uint256 public minted;
  uint256 public returnLength = 32;
  uint256 public failAt;

  constructor() ERC721("Boundary NFT", "BNFT") {}

  function configure(uint256 length, uint256 failure) external {
    returnLength = length;
    failAt = failure;
  }

  function mintTo(address recipient) external returns (uint256 tokenId) {
    tokenId = ++minted;
    if (tokenId == failAt) revert MintRejected();
    _mint(recipient, tokenId);
    uint256 length = returnLength;
    assembly ("memory-safe") {
      mstore(0, tokenId)
      return(0, length)
    }
  }
}

contract BoundaryOwnerResponse {
  uint256 public mutations;
  uint256 internal immutable mode;
  address internal immutable seller;

  constructor(address seller_, uint256 mode_) {
    seller = seller_;
    mode = mode_;
  }

  function owner() external returns (address) {
    uint256 value = uint160(seller);
    if (mode == 3) ++mutations;
    if (mode == 2) value |= uint256(1) << 160;
    uint256 length = mode == 0
      ? 0
      : mode == 1
        ? 20
        : 32;
    assembly ("memory-safe") {
      mstore(0, value)
      // Raw address bytes omit the twelve-byte ABI padding.
      if eq(length, 20) {
        return(12, 20)
      }
      return(0, length)
    }
  }
}

contract BoundaryApprovalToken is CartTestToken {
  bool public ignoreClear;
  bool public dirty;
  address public observedCart;
  address public observedSpender;

  constructor() CartTestToken("Boundary Payment", "BPAY") {}

  function configure(address cart, address spender, bool ignore) external {
    observedCart = cart;
    observedSpender = spender;
    ignoreClear = ignore;
  }

  function setDirty(bool value) external {
    dirty = value;
  }

  function approve(address spender, uint256 amount) public override returns (bool) {
    if (ignoreClear && amount == 0) return true;
    return super.approve(spender, amount);
  }

  function allowance(address owner, address spender) public view override returns (uint256) {
    if (dirty && owner == observedCart && spender == observedSpender) return 1;
    return super.allowance(owner, spender);
  }
}

contract BoundaryPermit2 is IPermit2Cart {
  mapping(bytes32 => uint160) internal amounts;
  bool public ignoreClear;
  function setIgnoreClear(bool value) external {
    ignoreClear = value;
  }
  function seed(address owner, address token, address spender, uint160 amount) external {
    amounts[keccak256(abi.encode(owner, token, spender))] = amount;
  }
  function approve(address token, address spender, uint160 amount, uint48) external override {
    if (ignoreClear && amount == 0) return;
    amounts[keccak256(abi.encode(msg.sender, token, spender))] = amount;
  }
  function allowance(
    address owner,
    address token,
    address spender
  ) external view override returns (uint160, uint48, uint48) {
    return (amounts[keccak256(abi.encode(owner, token, spender))], 0, 0);
  }
}

contract BoundaryAllowanceReceiver {
  BoundaryApprovalToken internal immutable token;
  bool public enabled = true;
  constructor(BoundaryApprovalToken token_) {
    token = token_;
  }
  function disable() external {
    enabled = false;
  }
  function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
    if (enabled) token.setDirty(true);
    return this.onERC721Received.selector;
  }
}

contract BoundarySpreadReceiver {
  address payable internal immutable cart;
  CartTestToken internal immutable token;
  constructor(address cart_, CartTestToken token_) {
    cart = payable(cart_);
    token = token_;
  }
  receive() external payable {
    if (address(token) == address(0)) {
      (bool success, ) = cart.call{value: 1}("");
      require(success, "return ETH");
    } else {
      require(token.transfer(cart, 1), "return token");
    }
  }
}

contract BoundaryReceiveWETH is CartTestWETH {
  // Model WETH9's deposit-on-receive behavior, absent from the ordinary unit mock.
  receive() external payable {
    _mint(msg.sender, msg.value);
  }
}

contract BoundaryCurrencyReceiver {
  uint256 public nativeReceived;
  receive() external payable {
    nativeReceived += msg.value;
  }
}

contract CartExternalBoundariesTest is CartFixture {
  struct Purchase {
    ICart.PurchaseOrder order;
    ICart.OrderLine[] lines;
    ICart.Listing[] listings;
    ICart.ListingPurchaseAuthorization authorization;
    ICart.PayoutRoute route;
    ICart.FulfillmentAction[] actions;
  }

  function testEveryTruncatedMintReturnRollsBackDeliveryAndPayment() public {
    BoundaryMint token = new BoundaryMint();
    token.transferOwnership(seller);
    Purchase memory p = _mintPurchase(address(token), 1, false);
    _fund(p);
    for (uint256 length; length < 32; ++length) {
      token.configure(length, 0);
      _reject(p, abi.encodeWithSelector(ICart.InvalidFulfillmentResult.selector, 0, 0, new bytes(length)));
      assertEq(token.minted(), 0);
      assertEq(token.balanceOf(collector), 0);
    }
    token.configure(32, 0);
    _succeed(p);
    assertEq(token.ownerOf(1), collector);
  }

  function testLaterMintUnitFailureRollsBackEarlierMint() public {
    _partialMint(false);
  }
  function testLaterActionFailureRollsBackEarlierMint() public {
    _partialMint(true);
  }

  function _partialMint(bool splitActions) internal {
    BoundaryMint token = new BoundaryMint();
    token.transferOwnership(seller);
    token.configure(32, 2);
    Purchase memory p = _mintPurchase(address(token), 2, splitActions);
    _fund(p);
    _reject(
      p,
      abi.encodeWithSelector(
        ICart.FulfillmentActionFailed.selector,
        0,
        splitActions ? 1 : 0,
        abi.encodeWithSelector(BoundaryMint.MintRejected.selector)
      )
    );
    assertEq(token.minted(), 0);
    assertEq(token.balanceOf(collector), 0);
    assertEq(token.balanceOf(payer), 0);
    vm.expectRevert("ERC721: invalid token ID");
    token.ownerOf(1);
    token.configure(32, 0);
    _succeed(p);
    assertEq(token.ownerOf(1), collector);
    assertEq(token.ownerOf(2), splitActions ? payer : collector);
  }

  function testMalformedCollectionOwnerResponsesFailExecutionAndLens() public {
    CartLens lens = new CartLens();
    for (uint256 mode; mode < 4; ++mode) {
      BoundaryOwnerResponse token = new BoundaryOwnerResponse(seller, mode);
      Purchase memory p = _mintPurchase(address(token), 1, false);
      _fund(p);
      ICartLens.ValidationResult memory result = lens.validateListing{gas: 2_000_000}(
        address(cart),
        p.listings[0],
        p.authorization.listingRoots[0],
        p.authorization.listingRootSignatures[0],
        p.authorization.listingProofs[0],
        1
      );
      assertFalse(result.valid);
      assertEq(uint256(result.code), uint256(ICartLens.ValidationCode.INVALID_LISTING));
      _reject(p, abi.encodeWithSelector(ICart.InvalidMintContractOwner.selector, address(token), seller));
      assertEq(token.mutations(), 0);
    }
  }

  function testNativeReturnedDuringFinalSpreadCallbackReverts() public {
    _returnedSpread(false);
  }
  function testTrackedTokenReturnedDuringFinalSpreadCallbackReverts() public {
    _returnedSpread(true);
  }

  function _returnedSpread(bool returnToken) internal {
    CartTestToken token = new CartTestToken("Tracked", "TRACK");
    BoundarySpreadReceiver recipient = new BoundarySpreadReceiver(
      address(cart),
      returnToken ? token : CartTestToken(address(0))
    );
    Purchase memory p = _offchainPurchase(sellerPayout);
    ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
    lines[0] = p.lines[0];
    lines[1] = ICart.OrderLine(
      keccak256("tracked-free-line"),
      bytes32(0),
      ICart.FulfillmentKind.NONE,
      1,
      address(token),
      0,
      collector
    );
    p.lines = lines;
    p.order.paymentAmount = 2 ether;
    p.order.spreadRecipient = address(recipient);
    token.mint(address(cart), 5 ether);
    token.mint(address(recipient), 1);
    _fund(p);
    _reject(
      p,
      abi.encodeWithSelector(
        ICart.UnexpectedCartBalance.selector,
        returnToken ? address(token) : address(0),
        returnToken ? 5 ether : 3 ether,
        (returnToken ? 5 ether : 3 ether) + 1
      )
    );
    assertEq(token.balanceOf(address(cart)), 5 ether);
    assertEq(token.balanceOf(address(recipient)), 1);
    assertEq(address(recipient).balance, 0);
  }

  function testCartAsSignedNativeSpreadRecipientFailsFinalBaselineCheck() public {
    Purchase memory p = _offchainPurchase(sellerPayout);
    p.order.paymentAmount = 2 ether;
    p.order.spreadRecipient = address(cart);
    _fund(p);
    _reject(p, abi.encodeWithSelector(ICart.UnexpectedCartBalance.selector, address(0), 3 ether, 4 ether));
  }

  function testPaymentTokenIgnoringAllowanceRevocationRollsBack() public {
    BoundaryApprovalToken payment = new BoundaryApprovalToken();
    payment.configure(address(cart), address(permit2), true);
    (Purchase memory p, CartTestToken output) = _routedPurchase(payment);
    _fund(p);
    _reject(p, abi.encodeWithSelector(ICart.AllowanceNotCleared.selector, address(payment), address(permit2)));
    _assertCleanApprovals(payment);
    payment.configure(address(cart), address(permit2), false);
    _succeed(p);
    assertEq(output.balanceOf(sellerPayout), 1 ether);
    _assertCleanApprovals(payment);
  }

  function testPermit2IgnoringAllowanceRevocationRollsBack() public {
    BoundaryPermit2 faulty = new BoundaryPermit2();
    _deployCart(address(faulty));
    faulty.setIgnoreClear(true);
    CartTestToken payment = new CartTestToken("Payment", "PAY");
    (Purchase memory p, CartTestToken output) = _routedPurchase(payment);
    _fund(p);
    _reject(p, abi.encodeWithSelector(ICart.AllowanceNotCleared.selector, address(payment), address(router)));
    _assertCleanApprovals(payment);
    faulty.setIgnoreClear(false);
    _succeed(p);
    assertEq(output.balanceOf(sellerPayout), 1 ether);
    _assertCleanApprovals(payment);
  }

  function testPermit2OnlyPreexistingAllowanceIsPreserved() public {
    CartTestToken payment = new CartTestToken("Payment", "PAY");
    (Purchase memory p, ) = _routedPurchase(payment);
    _fund(p);
    vm.prank(address(cart));
    permit2.approve(address(payment), address(router), 7, uint48(block.timestamp + 1 days));
    assertEq(payment.allowance(address(cart), address(permit2)), 0);
    _reject(p, abi.encodeWithSelector(ICart.PreexistingAllowance.selector, address(payment), address(router), 7));
    (uint160 amount, , ) = permit2.allowance(address(cart), address(payment), address(router));
    assertEq(amount, 7);
    assertEq(router.executeCalls(), 0);
  }

  function testAllowanceChangedDuringNftCallbackIsRejectedAtFinish() public {
    BoundaryApprovalToken payment = new BoundaryApprovalToken();
    payment.configure(address(cart), address(permit2), false);
    (Purchase memory p, CartTestToken output) = _routedPurchase(payment);
    CartTestERC721 nft = new CartTestERC721();
    BoundaryAllowanceReceiver recipient = new BoundaryAllowanceReceiver(payment);
    nft.mint(seller, 1);
    vm.prank(seller);
    nft.setApprovalForAll(address(cart), true);
    p.listings[0].fulfillmentKind = ICart.FulfillmentKind.ERC721_TRANSFER;
    p.listings[0].tokenContract = address(nft);
    p.listings[0].tokenId = 1;
    p.lines[0].listingDigest = _listingDigest(p.listings[0]);
    p.lines[0].fulfillmentKind = ICart.FulfillmentKind.ERC721_TRANSFER;
    p.authorization = _rootAuthorization(p.listings, SELLER_PK);
    p.actions = new ICart.FulfillmentAction[](1);
    p.actions[0] = ICart.FulfillmentAction(0, 1, address(recipient));
    _fund(p);
    _reject(p, abi.encodeWithSelector(ICart.AllowanceNotCleared.selector, address(payment), address(permit2)));
    assertEq(nft.ownerOf(1), seller);
    assertFalse(payment.dirty());
    _assertCleanApprovals(payment);
    recipient.disable();
    _succeed(p);
    assertEq(nft.ownerOf(1), address(recipient));
    assertEq(output.balanceOf(sellerPayout), 1 ether);
    _assertCleanApprovals(payment);
  }

  function testWethPaymentWithoutRouteSettlesNativeEth() public {
    _wethPayment(false);
  }
  function testWethPaymentKeepsEthAndWethPayoutsToSameRecipientSeparate() public {
    _wethPayment(true);
  }

  function _wethPayment(bool mixed) internal {
    BoundaryCurrencyReceiver recipient = new BoundaryCurrencyReceiver();
    Purchase memory p = _offchainPurchase(address(recipient));
    if (mixed) {
      ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
      lines[0] = p.lines[0];
      lines[1] = ICart.OrderLine(
        keccak256("weth-payout"),
        bytes32(0),
        ICart.FulfillmentKind.NONE,
        1,
        address(weth),
        1 ether,
        address(recipient)
      );
      p.lines = lines;
      p.order.paymentAmount = 2 ether;
    }
    p.order.paymentCurrency = address(weth);
    _fund(p);
    _succeed(p);
    assertEq(recipient.nativeReceived(), 1 ether);
    assertEq(address(recipient).balance, 1 ether);
    assertEq(weth.balanceOf(address(recipient)), mixed ? 1 ether : 0);
    assertEq(address(cart).balance, 3 ether);
    assertEq(weth.balanceOf(address(cart)), 4 ether);
    assertEq(weth.balanceOf(payer), 0);
    assertEq(router.executeCalls(), 0);
    _assertCleanApprovals(weth);
  }

  function testNativePayoutToDepositOnReceiveWethReturnsWethAsSignedSpread() public {
    weth = new BoundaryReceiveWETH();
    _deployCart(address(permit2));
    Purchase memory p = _offchainPurchase(address(weth));
    p.order.spreadRecipient = collector;
    _fund(p);
    _succeed(p);
    assertEq(address(weth).balance, 1 ether);
    assertEq(weth.balanceOf(collector), 1 ether);
    assertEq(weth.balanceOf(address(weth)), 0);
    assertEq(address(cart).balance, 3 ether);
    assertEq(weth.balanceOf(address(cart)), 4 ether);
  }

  function _mintPurchase(address token, uint256 quantity, bool split) internal returns (Purchase memory p) {
    ICart.Listing memory listing = _listingWithQuantity(
      keccak256("mint-boundary"),
      ICart.FulfillmentKind.ERC721_MINT_TO,
      token,
      0,
      sellerPayout,
      quantity
    );
    p = _build(listing, quantity);
    p.actions = new ICart.FulfillmentAction[](split ? 2 : 1);
    p.actions[0] = ICart.FulfillmentAction(0, split ? 1 : quantity, collector);
    if (split) p.actions[1] = ICart.FulfillmentAction(0, 1, payer);
  }

  function _offchainPurchase(address recipient) internal returns (Purchase memory) {
    return _build(_listing(keccak256("boundary"), ICart.FulfillmentKind.NONE, address(0), 0, recipient), 1);
  }

  function _build(ICart.Listing memory listing, uint256 quantity) internal returns (Purchase memory p) {
    p.lines = _lineForListing(listing, quantity, listing.minimumUnitPrice * quantity);
    p.lines[0].settlementCurrency = listing.settlementCurrency;
    p.listings = _singletonListing(listing);
    p.authorization = _rootAuthorization(p.listings, SELLER_PK);
    p.actions = new ICart.FulfillmentAction[](0);
    p.route = _emptyRoute();
    p.order = _order("external-boundary", p.lines, p.route, p.actions);
  }

  function _routedPurchase(CartTestToken payment) internal returns (Purchase memory p, CartTestToken output) {
    output = new CartTestToken("Output", "OUT");
    ICart.Listing memory listing = _listing(
      keccak256("routed-boundary"),
      ICart.FulfillmentKind.NONE,
      address(0),
      0,
      sellerPayout
    );
    listing.settlementCurrency = address(output);
    p = _build(listing, 1);
    p.order.paymentCurrency = address(payment);
    p.route = ICart.PayoutRoute(hex"08", new bytes[](1), 0);
    p.route.inputs[0] = _mockRouteInput(0x08);
    router.configure(address(output), 1 ether, 0, false);
    output.mint(address(cart), 5 ether);
  }

  function _fund(Purchase memory p) internal {
    vm.deal(address(cart), 3 ether);
    weth.mint(address(cart), 4 ether - weth.balanceOf(address(cart)));
    vm.deal(payer, 10 ether);
    if (p.order.paymentCurrency != address(0)) {
      if (p.order.paymentCurrency == address(weth)) {
        vm.prank(payer);
        weth.deposit{value: p.order.paymentAmount}();
      } else {
        CartTestToken(p.order.paymentCurrency).mint(payer, p.order.paymentAmount);
        CartTestToken(p.order.paymentCurrency).mint(address(cart), 3 ether);
      }
      vm.prank(payer);
      IERC20(p.order.paymentCurrency).approve(address(cart), p.order.paymentAmount);
    }
  }

  function _invoke(Purchase memory p) internal returns (bool, bytes memory) {
    p.order.orderLinesHash = hashes.hashOrderLines(p.lines);
    p.order.payoutRouteHash = hashes.hashPayoutRoute(p.route);
    p.order.fulfillmentActionsHash = hashes.hashFulfillmentActions(p.actions);
    bytes memory signature = _sign(PLATFORM_PK, _orderDigest(p.order));
    bytes memory payload = abi.encodeCall(
      Cart.executePurchase,
      (p.order, p.lines, p.listings, p.authorization, p.route, p.actions, signature)
    );
    vm.prank(payer);
    return
      address(cart).call{value: p.order.paymentCurrency == address(0) ? p.order.paymentAmount : 0, gas: 5_000_000}(
        payload
      );
  }

  function _reject(Purchase memory p, bytes memory expected) internal {
    uint256 nativeBefore = address(cart).balance;
    uint256 wethBefore = weth.balanceOf(address(cart));
    uint256 payerBefore = payer.balance;
    uint256 inputBefore;
    if (p.order.paymentCurrency != address(0)) inputBefore = IERC20(p.order.paymentCurrency).balanceOf(payer);
    uint256[] memory cartBefore = new uint256[](p.lines.length);
    uint256[] memory recipientBefore = new uint256[](p.lines.length);
    for (uint256 i; i < p.lines.length; ++i) {
      address currency = p.lines[i].settlementCurrency;
      cartBefore[i] = currency == address(0) ? nativeBefore : IERC20(currency).balanceOf(address(cart));
      recipientBefore[i] = currency == address(0)
        ? p.lines[i].paymentRecipient.balance
        : IERC20(currency).balanceOf(p.lines[i].paymentRecipient);
    }
    (bool success, bytes memory result) = _invoke(p);
    assertFalse(success);
    assertEq(result, expected);
    assertEq(address(cart).balance, nativeBefore);
    assertEq(weth.balanceOf(address(cart)), wethBefore);
    assertEq(payer.balance, payerBefore);
    if (p.order.paymentCurrency != address(0)) {
      assertEq(IERC20(p.order.paymentCurrency).balanceOf(payer), inputBefore);
      assertEq(IERC20(p.order.paymentCurrency).balanceOf(address(cart)), 3 ether);
      assertEq(IERC20(p.order.paymentCurrency).allowance(payer, address(cart)), p.order.paymentAmount);
    }
    assertFalse(cart.executedOrderIds(p.order.orderId));
    for (uint256 i; i < p.listings.length; ++i) assertEq(cart.filledQuantity(_listingDigest(p.listings[i])), 0);
    for (uint256 i; i < p.lines.length; ++i) {
      address currency = p.lines[i].settlementCurrency;
      assertEq(
        currency == address(0) ? address(cart).balance : IERC20(currency).balanceOf(address(cart)),
        cartBefore[i]
      );
      assertEq(
        currency == address(0)
          ? p.lines[i].paymentRecipient.balance
          : IERC20(currency).balanceOf(p.lines[i].paymentRecipient),
        recipientBefore[i]
      );
    }
  }

  function _succeed(Purchase memory p) internal {
    (bool success, bytes memory result) = _invoke(p);
    assertTrue(success, string(result));
    assertTrue(cart.executedOrderIds(p.order.orderId));
    for (uint256 i; i < p.listings.length; ++i) {
      assertEq(cart.filledQuantity(_listingDigest(p.listings[i])), p.lines[0].quantity);
    }
  }

  function _assertCleanApprovals(IERC20 token) internal {
    assertEq(token.allowance(address(cart), cart.permit2()), 0);
    (uint160 amount, , ) = IPermit2Cart(cart.permit2()).allowance(address(cart), address(token), address(router));
    assertEq(amount, 0);
  }

  function _deployCart(address permit) internal {
    Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
    cart = Cart(
      payable(
        address(
          new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(Cart.initialize, (address(this), platformSigner, address(router), permit, address(weth)))
          )
        )
      )
    );
  }
}
