// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartFixture} from "./CartFixture.sol";
import {CartTestERC721, CartTestFeeOnTransferToken, CartTestToken} from "./CartMocks.sol";
import {Cart} from "../../cart/Cart.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {CartLens} from "../../cart/CartLens.sol";
import {ICart} from "../../cart/ICart.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Deliberately dishonest seller collection. Successful calls do not imply delivery.
contract CartDishonestCollection is ERC721, Ownable {
    address public mintRecipient;
    constructor() ERC721("Dishonest", "LIE") {}

    function mint(address to) external {
        _mint(to, 1);
    }

    function setMintRecipient(address to) external {
        mintRecipient = to;
    }
    function safeTransferFrom(address, address, uint256) public override {}

    function mintTo(address) external returns (uint256) {
        _mint(mintRecipient, 2);
        return 2;
    }
}

contract CartPayoutReentry {
    address internal immutable cart;
    bytes internal payload;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    constructor(address cart_, bytes memory payload_) {
        cart = cart_;
        payload = payload_;
    }

    receive() external payable {
        attempted = true;
        (succeeded, result) = cart.call{value: 1 ether}(payload);
    }
}

contract CartCallbackBurnToken is CartTestToken {
    constructor() CartTestToken("Burnable", "BURN") {}

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract CartBalanceDropReceiver {
    CartCallbackBurnToken internal immutable token;
    address internal immutable cart;

    constructor(CartCallbackBurnToken token_, address cart_) {
        token = token_;
        cart = cart_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        token.burn(cart, 1);
        return this.onERC721Received.selector;
    }
}

contract CartAdversarialTest is CartFixture {
    struct Purchase {
        ICart.PurchaseOrder order;
        ICart.OrderLine[] lines;
        ICart.Listing[] listings;
        ICart.ListingPurchaseAuthorization authorization;
        ICart.PayoutRoute route;
        ICart.FulfillmentAction[] actions;
        bytes signature;
    }

    function _purchase(ICart.Listing memory listing, bool deliver) internal returns (Purchase memory p) {
        p.lines = _lineForListing(listing, 1, 1 ether);
        p.listings = _singletonListing(listing);
        p.authorization = _rootAuthorization(p.listings, SELLER_PK);
        p.route = _emptyRoute();
        p.actions = new ICart.FulfillmentAction[](deliver ? 1 : 0);
        if (deliver) p.actions[0] = ICart.FulfillmentAction(0, 1, collector);
        p.order = _order("adversarial", p.lines, _emptyRoute(), p.actions);
        _signPurchase(p);
    }

    function _signPurchase(Purchase memory p) internal {
        p.order.orderLinesHash = hashes.hashOrderLines(p.lines);
        p.order.payoutRouteHash = hashes.hashPayoutRoute(p.route);
        p.order.fulfillmentActionsHash = hashes.hashFulfillmentActions(p.actions);
        p.signature = _sign(PLATFORM_PK, _orderDigest(p.order));
    }

    function _callData(Purchase memory p) internal pure returns (bytes memory) {
        return abi.encodeCall(
            Cart.executePurchase, (p.order, p.lines, p.listings, p.authorization, p.route, p.actions, p.signature)
        );
    }

    function _assertReverts(Purchase memory p, bytes memory reason) internal {
        vm.deal(payer, 2 ether);
        uint256 ethBefore = address(cart).balance;
        uint256 wethBefore = weth.balanceOf(address(cart));
        uint256 recipientBefore = p.lines[0].paymentRecipient.balance;
        vm.prank(payer);
        (bool success, bytes memory result) = address(cart).call{value: p.order.paymentAmount}(_callData(p));
        assertFalse(success);
        assertEq(result, reason);
        assertEq(payer.balance, 2 ether);
        assertEq(address(cart).balance, ethBefore);
        assertEq(weth.balanceOf(address(cart)), wethBefore);
        assertEq(p.lines[0].paymentRecipient.balance, recipientBefore);
        assertFalse(cart.executedOrderIds(p.order.orderId));
        for (uint256 i; i < p.listings.length; ++i) {
            assertEq(cart.filledQuantity(_listingDigest(p.listings[i])), 0);
        }
    }

    function _offchain() internal view returns (ICart.Listing memory) {
        return _listing(keccak256("adversarial"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
    }

    function testSignedLineBelowSellerMinimum() public {
        _termsMismatch(0);
    }

    function testSignedLineChangesPaymentRecipient() public {
        _termsMismatch(1);
    }

    function testSignedLineChangesSettlementCurrency() public {
        _termsMismatch(2);
    }

    function testSignedLineChangesFulfillmentKind() public {
        _termsMismatch(3);
    }

    function testSellerMinimumMultiplicationOverflowBeforeFunding() public {
        _termsMismatch(4);
    }

    function _termsMismatch(uint256 variant) internal {
        ICart.Listing memory listing = _offchain();
        if (variant == 0) listing.minimumUnitPrice = 0.5 ether;
        listing.availableQuantity = 2;
        if (variant == 4) listing.minimumUnitPrice = 2;
        listing.availableQuantity = 0;
        Purchase memory p = _purchase(listing, false);
        if (variant == 0) {
            p.lines[0].quantity = 2;
            p.lines[0].amount = 1 ether - 1;
            p.order.paymentAmount = p.lines[0].amount;
        }
        if (variant == 1) p.lines[0].paymentRecipient = collector;
        if (variant == 2) p.lines[0].settlementCurrency = address(weth);
        if (variant == 3) p.lines[0].fulfillmentKind = ICart.FulfillmentKind.OFF_CHAIN;
        if (variant == 4) p.lines[0].quantity = type(uint256).max / 2 + 1;
        _signPurchase(p);
        _assertPreflight(p);
        _assertReverts(p, abi.encodeWithSelector(ICart.ListingTermsMismatch.selector, 0));
        assertEq(router.executeCalls(), 0);
    }

    function _assertPreflight(Purchase memory p) internal {
        CartLens lens = new CartLens();
        assertTrue(
            lens.validateListing(
                address(cart),
                p.listings[0],
                p.authorization.listingRoots[0],
                p.authorization.listingRootSignatures[0],
                p.authorization.listingProofs[0],
                p.lines[0].quantity
            )
            .valid
        );
        assertTrue(
            lens.validatePurchaseEnvelope(address(cart), p.order, p.lines, p.route, p.actions, p.signature).valid
        );
    }

    function testAttackerSignedRootCannotAuthorizeStolenVictimLeaf() public {
        Purchase memory p = _purchase(_offchain(), false);
        p.authorization = _rootAuthorization(p.listings, PAYER_PK);
        bytes32 digest = hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), p.authorization.listingRoots[0]);
        _assertReverts(p, abi.encodeWithSelector(ICart.InvalidSignature.selector, seller, digest));
    }

    function _nftPurchase() internal returns (Purchase memory p, CartTestERC721 token) {
        token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        p = _purchase(
            _listing(keccak256("nft"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout), true
        );
    }

    function testApprovalRevokedAfterValidPreflight() public {
        (Purchase memory p, CartTestERC721 token) = _nftPurchase();
        _assertPreflight(p);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), false);
        _assertReverts(
            p,
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                0,
                0,
                abi.encodeWithSignature("Error(string)", "ERC721: caller is not token owner or approved")
            )
        );
        assertEq(token.ownerOf(1), seller);
    }

    function testTokenMovedAfterSigning() public {
        (Purchase memory p, CartTestERC721 token) = _nftPurchase();
        vm.prank(seller);
        token.transferFrom(seller, collector, 1);
        _assertReverts(
            p,
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                0,
                0,
                abi.encodeWithSignature("Error(string)", "ERC721: caller is not token owner or approved")
            )
        );
        assertEq(token.ownerOf(1), collector);
    }

    function testDifferentSaltsCannotSellSameErc721Twice() public {
        (Purchase memory first, CartTestERC721 token) = _nftPurchase();
        ICart.Listing memory secondListing = abi.decode(abi.encode(first.listings[0]), (ICart.Listing));
        secondListing.listingSalt = keccak256("second-salt");
        Purchase memory second = _purchase(secondListing, true);
        second.order.orderId = keccak256("second-order");
        _signPurchase(second);
        vm.deal(payer, 2 ether);
        vm.prank(payer);
        (bool success,) = address(cart).call{value: 1 ether}(_callData(first));
        assertTrue(success);
        _assertReverts(
            second,
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                0,
                0,
                abi.encodeWithSignature("Error(string)", "ERC721: caller is not token owner or approved")
            )
        );
        assertTrue(cart.executedOrderIds(first.order.orderId));
        assertEq(cart.filledQuantity(first.lines[0].listingDigest), 1);
        assertEq(token.ownerOf(1), collector);
    }

    function testPreflightDoesNotGuaranteeActionCoverage() public {
        (Purchase memory p, CartTestERC721 token) = _nftPurchase();
        p.actions = new ICart.FulfillmentAction[](0);
        _signPurchase(p);
        _assertPreflight(p);
        _assertReverts(p, abi.encodeWithSelector(ICart.InvalidFulfillmentAction.selector, 0));
        assertEq(token.ownerOf(1), seller);
    }

    function testSuccessfulNoOpTransferConsumesOrderAndPaysSeller() public {
        CartDishonestCollection token = new CartDishonestCollection();
        token.mint(seller);
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        Purchase memory p = _purchase(
            _listing(keccak256("no-op"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout), true
        );
        _assertDishonestPurchaseSucceeds(p);
        assertEq(token.ownerOf(1), seller);
    }

    function testSuccessfulMintToSellerConsumesOrderAndPaysSeller() public {
        _wrongMint(seller);
    }

    function testSuccessfulMintToCartConsumesOrderAndPaysSeller() public {
        _wrongMint(address(cart));
    }

    function _wrongMint(address recipient) internal {
        CartDishonestCollection token = new CartDishonestCollection();
        token.setMintRecipient(recipient);
        token.transferOwnership(seller);
        Purchase memory p = _purchase(
            _listing(keccak256("wrong-mint"), ICart.FulfillmentKind.ERC721_MINT_TO, address(token), 0, sellerPayout),
            true
        );
        _assertDishonestPurchaseSucceeds(p);
        assertEq(token.ownerOf(2), recipient);
    }

    function _assertDishonestPurchaseSucceeds(Purchase memory p) internal {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool success,) = address(cart).call{value: 1 ether}(_callData(p));
        assertTrue(success);
        assertTrue(cart.executedOrderIds(p.order.orderId));
        assertEq(cart.filledQuantity(p.lines[0].listingDigest), 1);
        assertEq(payer.balance, 0);
        assertEq(sellerPayout.balance, 1 ether);
        assertEq(address(cart).balance, 0);
    }

    function testEthPayoutCannotReenterIndependentFundedPurchase() public {
        bytes memory inner = _signedInnerPurchase();
        CartPayoutReentry recipient = new CartPayoutReentry(address(cart), inner);
        vm.deal(address(recipient), 1 ether);
        vm.deal(address(cart), 3 ether);
        weth.mint(address(cart), 4 ether);
        ICart.Listing memory listing = _offchain();
        listing.paymentRecipient = address(recipient);
        Purchase memory p = _purchase(listing, false);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool success,) = address(cart).call{value: 1 ether}(_callData(p));
        assertTrue(success);
        assertTrue(recipient.attempted());
        assertFalse(recipient.succeeded());
        assertEq(recipient.result(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertFalse(cart.executedOrderIds(keccak256("signed-inner-purchase")));
        assertEq(address(recipient).balance, 2 ether);
        assertEq(address(cart).balance, 3 ether);
        assertEq(weth.balanceOf(address(cart)), 4 ether);
        // The same funded call succeeds once the outer purchase has returned.
        vm.prank(address(recipient));
        (success,) = address(cart).call{value: 1 ether}(inner);
        assertTrue(success);
        assertTrue(cart.executedOrderIds(keccak256("signed-inner-purchase")));
        assertEq(sellerPayout.balance, 1 ether);
    }

    function testEcdsaOrderCannotReplayAfterChainIdChange() public {
        vm.chainId(1);
        Purchase memory p = _purchase(_offchain(), false);
        vm.chainId(2);
        _assertReverts(
            p, abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(p.order))
        );
    }

    function testEcdsaOrderCannotReplayAcrossProxies() public {
        Purchase memory p = _purchase(_offchain(), false);
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        Cart other = Cart(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            Cart.initialize,
                            (address(this), platformSigner, address(router), address(permit2), address(weth))
                        )
                    )
                ))
        );
        p.signature = _sign(PLATFORM_PK, hashes.hashOrder(other.DOMAIN_SEPARATOR(), p.order));
        _assertReverts(
            p, abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(p.order))
        );
    }

    function testEcdsaRejectsHighS() public {
        Purchase memory p = _purchase(_offchain(), false);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PLATFORM_PK, _orderDigest(p.order));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        p.signature = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27));
        _assertReverts(
            p, abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(p.order))
        );
    }

    function testEcdsaRejectsEmptySignature() public {
        Purchase memory p = _purchase(_offchain(), false);
        p.signature = "";
        _assertReverts(
            p, abi.encodeWithSelector(ICart.InvalidSignature.selector, platformSigner, _orderDigest(p.order))
        );
    }

    function testOrderDeadlineIsInclusive() public {
        _deadlineBoundary(false);
    }

    function testListingRootDeadlineIsInclusive() public {
        _deadlineBoundary(true);
    }

    function _deadlineBoundary(bool root) internal {
        Purchase memory p = _purchase(_offchain(), false);
        uint256 deadline = block.timestamp + 100;
        if (root) {
            p.authorization.listingRoots[0].deadline = deadline;
            p.authorization.listingRootSignatures[0] =
                _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), p.authorization.listingRoots[0]));
        } else {
            p.order.deadline = deadline;
            _signPurchase(p);
        }
        uint256 snapshot = vm.snapshot();
        vm.warp(deadline);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool success,) = address(cart).call{value: 1 ether}(_callData(p));
        assertTrue(success);
        assertEq(sellerPayout.balance, 1 ether);
        assertTrue(vm.revertTo(snapshot));
        vm.warp(deadline + 1);
        _assertReverts(p, abi.encodeWithSelector(ICart.DeadlineExpired.selector, deadline, deadline + 1));
    }

    function testFeeOnTransferSettlementRefundsPayer() public {
        CartTestFeeOnTransferToken token = new CartTestFeeOnTransferToken();
        ICart.Listing memory listing = _offchain();
        listing.settlementCurrency = address(token);
        Purchase memory p = _purchase(listing, false);
        p.lines[0].settlementCurrency = address(token);
        p.route = ICart.PayoutRoute(hex"08", new bytes[](1), 1 ether);
        router.configure(address(token), 1 ether, 0, false);
        _signPurchase(p);
        _assertReverts(
            p,
            abi.encodeWithSelector(
                ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, abi.encode(1 ether, 1 ether - 1)
            )
        );
        assertEq(token.balanceOf(sellerPayout), 0);
        assertEq(token.balanceOf(address(cart)), 0);
    }

    function testNftCallbackCannotPaySellerFromCartInventory() public {
        (Purchase memory p, CartTestERC721 nft) = _nftPurchase();
        CartCallbackBurnToken token = new CartCallbackBurnToken();
        CartBalanceDropReceiver receiver = new CartBalanceDropReceiver(token, address(cart));
        token.mint(address(cart), 5 ether);
        p.listings[0].settlementCurrency = address(token);
        p.lines = _lineForListing(p.listings[0], 1, 1 ether);
        p.lines[0].settlementCurrency = address(token);
        p.authorization = _rootAuthorization(p.listings, SELLER_PK);
        p.actions[0].recipient = address(receiver);
        p.route = ICart.PayoutRoute(hex"08", new bytes[](1), 1 ether);
        router.configure(address(token), 1 ether, 0, false);
        _signPurchase(p);
        // The payout is exact, but consuming one wei of the baseline must roll everything back.
        _assertReverts(
            p, abi.encodeWithSelector(ICart.PreexistingBalanceConsumed.selector, address(token), 5 ether, 5 ether - 1)
        );
        assertEq(token.balanceOf(address(cart)), 5 ether);
        assertEq(token.balanceOf(sellerPayout), 0);
        assertEq(nft.ownerOf(1), seller);
    }

    function testNonOwnerCannotAdministerOrUpgrade() public {
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        vm.startPrank(payer);
        vm.expectRevert("Ownable: caller is not the owner");
        cart.upgradeTo(address(implementation));
        vm.expectRevert("Ownable: caller is not the owner");
        cart.setPaused(true);
        vm.expectRevert("Ownable: caller is not the owner");
        cart.setPlatformSigner(payer);
        vm.expectRevert("Ownable: caller is not the owner");
        cart.setProtocolRecipient(payer);
        vm.stopPrank();
        assertFalse(cart.paused());
        assertEq(cart.platformSigner(), platformSigner);
        assertEq(cart.protocolRecipient(), address(this));
    }

    function testImplementationCannotInitialize() public {
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(payer, platformSigner, address(router), address(permit2), address(weth));
    }

    function testPaymentExecutorRejectsDirectBegin() public {
        Purchase memory p = _purchase(_offchain(), false);
        vm.expectRevert(CartPayments.DirectCallNotAllowed.selector);
        paymentExecutor.begin(p.order, p.lines, p.route);
    }
}
