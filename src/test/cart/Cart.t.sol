// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

import {Cart} from "../../cart/Cart.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {CartHashes} from "../../cart/CartHashes.sol";
import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {ICart} from "../../cart/ICart.sol";
import {IPermit2Cart} from "../../cart/IPermit2Cart.sol";

contract CartTestWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface ICartTestMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract CartTestRouter {
    ICartTestMintableToken internal outputToken;
    uint256 internal outputAmount;
    uint256 internal retainedAmount;
    bool internal useExistingBalance;
    address internal settlementPermit2;
    address internal settlementSink;
    address internal settlementInputToken;
    bool internal settlementMode;
    uint256 internal settlementInputAmount;
    uint256 public executeCalls;
    address[] internal multiOutputTokens;
    uint256[] internal multiOutputAmounts;
    address[] internal multiOutputRecipients;
    bool internal multiMode;
    address public observedPermit2;
    address public observedToken;
    uint256 public observedCartAllowance;
    uint160 public observedPermit2Allowance;
    uint256 public lastRouterValue;
    bytes public lastCommands;
    uint256 public lastInputCount;
    bool internal revertExecution;

    function configure(address token, uint256 output, uint256 retained, bool useExisting) external {
        outputToken = ICartTestMintableToken(token);
        outputAmount = output;
        retainedAmount = retained;
        useExistingBalance = useExisting;
        multiMode = false;
        settlementMode = false;
    }

    function configureSettlement(
        address permit2_,
        address sink_,
        address inputToken_,
        address outputToken_,
        uint256 inputAmount_,
        uint256 outputAmount_
    ) external {
        settlementPermit2 = permit2_;
        settlementSink = sink_;
        settlementInputToken = inputToken_;
        settlementInputAmount = inputAmount_;
        outputToken = ICartTestMintableToken(outputToken_);
        outputAmount = outputAmount_;
        settlementMode = true;
        multiMode = false;
    }

    function configureMulti(address[] calldata tokens, uint256[] calldata amounts) external {
        require(tokens.length == amounts.length, "length mismatch");
        delete multiOutputTokens;
        delete multiOutputAmounts;
        delete multiOutputRecipients;
        for (uint256 i = 0; i < tokens.length; ++i) {
            multiOutputTokens.push(tokens[i]);
            multiOutputAmounts.push(amounts[i]);
        }
        multiMode = true;
        settlementMode = false;
    }

    function configureMultiTo(address[] calldata tokens, uint256[] calldata amounts, address[] calldata recipients)
        external
    {
        require(tokens.length == amounts.length && tokens.length == recipients.length, "length mismatch");
        delete multiOutputTokens;
        delete multiOutputAmounts;
        delete multiOutputRecipients;
        for (uint256 i = 0; i < tokens.length; ++i) {
            multiOutputTokens.push(tokens[i]);
            multiOutputAmounts.push(amounts[i]);
            multiOutputRecipients.push(recipients[i]);
        }
        multiMode = true;
        settlementMode = false;
    }

    function configureApprovalObservation(address permit2_, address token_) external {
        observedPermit2 = permit2_;
        observedToken = token_;
    }

    function configureRevert(bool value) external {
        revertExecution = value;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        executeCalls++;
        lastRouterValue = msg.value;
        lastCommands = commands;
        lastInputCount = inputs.length;
        if (observedPermit2 != address(0)) {
            observedCartAllowance = IERC20(observedToken).allowance(msg.sender, observedPermit2);
            (observedPermit2Allowance,,) =
                IPermit2Cart(observedPermit2).allowance(msg.sender, observedToken, address(this));
        }
        if (revertExecution) revert("router reverted");
        if (multiMode) {
            require(commands.length == inputs.length && commands.length != 0, "unexpected route");
            for (uint256 i = 0; i < multiOutputTokens.length; ++i) {
                address recipient = multiOutputRecipients.length == 0 ? msg.sender : multiOutputRecipients[i];
                if (multiOutputTokens[i] == address(0)) {
                    (bool success,) = recipient.call{value: multiOutputAmounts[i]}("");
                    require(success, "native output failed");
                } else {
                    ICartTestMintableToken(multiOutputTokens[i]).mint(recipient, multiOutputAmounts[i]);
                }
            }
            return;
        }
        if (settlementMode) {
            require(commands.length != 0 && commands.length == inputs.length, "unexpected route");
            uint256 totalOutput;
            for (uint256 i = 0; i < inputs.length; ++i) {
                require(commands[i] == bytes1(0x09), "unexpected command");
                (address recipient, uint256 amountOut,, address[] memory path, bool payerIsUser) =
                    abi.decode(inputs[i], (address, uint256, uint256, address[], bool));
                require(recipient == address(1) && payerIsUser, "invalid route input");
                require(
                    path.length == 2 && path[0] == settlementInputToken && path[1] == address(outputToken),
                    "invalid path"
                );
                totalOutput += amountOut;
            }

            CartTestPermit2(settlementPermit2)
                .transferFrom(msg.sender, settlementSink, uint160(settlementInputAmount), settlementInputToken);
            require(totalOutput == outputAmount, "unexpected output");
            require(outputToken.transfer(msg.sender, totalOutput), "router transfer failed");
            return;
        }

        if (useExistingBalance) {
            require(outputToken.transfer(msg.sender, outputAmount), "router transfer failed");
        } else {
            outputToken.mint(msg.sender, outputAmount);
        }
        if (retainedAmount != 0) outputToken.mint(address(this), retainedAmount);
    }

    receive() external payable {}
}

contract CartTestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CartTestRevertingTransferToken is ERC20 {
    address internal rejectingRecipient;

    constructor() ERC20("Reverting Transfer Token", "RTT") {}

    function setRejectingRecipient(address recipient) external {
        rejectingRecipient = recipient;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != rejectingRecipient, "rejected recipient");
        return super.transfer(to, amount);
    }
}

contract CartTestFeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount == 0 ? 0 : 1;
        if (fee != 0) _burn(from, fee);
        super._transfer(from, to, amount - fee);
    }
}

contract CartTestPermit2 is IPermit2Cart {
    struct Approval {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Approval))) internal approvals;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external override {
        Approval storage approval = approvals[msg.sender][token][spender];
        approval.amount = amount;
        approval.expiration = expiration;
    }

    /// @dev Minimal stateful transfer path used by CartTestRouter to model Permit2's
    ///      router-spender allowance and the underlying ERC-20 allowance from Cart.
    function transferFrom(address from, address to, uint160 amount, address token) external {
        Approval storage approval = approvals[from][token][msg.sender];
        require(approval.expiration >= block.timestamp && approval.amount >= amount, "permit2 allowance");
        approval.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount), "token transfer failed");
    }

    function allowance(address owner, address token, address spender)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Approval memory approval = approvals[owner][token][spender];
        return (approval.amount, approval.expiration, approval.nonce);
    }
}

contract CartTestERC721 is ERC721 {
    constructor() ERC721("Cart NFT", "CNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract ReentrantERC721 is ERC721 {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) ERC721("Reentrant Cart NFT", "RCNFT") {
        cart = cart_;
    }

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public override {
        _attemptReentry();
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
        _attemptReentry();
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: caller is not owner nor approved");
        _safeTransfer(from, to, tokenId, data);
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}

contract CartTestMintableERC721 is ERC721, Ownable {
    mapping(address => bool) internal minters;
    uint256 internal nextTokenId = 1;

    constructor() ERC721("Cart Mintable NFT", "CMNFT") {}

    function setMinter(address account, bool value) external onlyOwner {
        minters[account] = value;
    }

    function mintTo(address to) external returns (uint256 tokenId) {
        require(msg.sender == owner() || minters[msg.sender], "not minter");
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }
}

contract CartTestERC1155 is ERC1155, Ownable {
    mapping(address => bool) internal minters;

    constructor() ERC1155("") {}

    function setMinter(address account, bool value) external onlyOwner {
        minters[account] = value;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function mintTo(address to, uint256 tokenId, uint256 amount) external {
        require(msg.sender == owner() || minters[msg.sender], "not minter");
        _mint(to, tokenId, amount, "");
    }
}

contract ReentrantERC1155 is ERC1155 {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) ERC1155("") {
        cart = cart_;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public override {
        _attemptReentry();
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeTransferFrom(from, to, id, amount, data);
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}

contract RevertingPayoutRecipient {
    receive() external payable {
        revert("payout rejected");
    }
}

contract ReentrantSellerReceiver {
    Cart internal immutable cart;
    bytes32 internal rootDigest;

    bool public cancelRootCallSucceeded;
    bool public nonceCallSucceeded;

    constructor(Cart cart_, bytes32 rootDigest_) {
        cart = cart_;
        rootDigest = rootDigest_;
    }

    function approveCart(IERC721 token, address spender) external {
        token.setApprovalForAll(spender, true);
    }

    function setRootDigest(bytes32 rootDigest_) external {
        rootDigest = rootDigest_;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (cancelRootCallSucceeded,) = address(cart).call(abi.encodeCall(Cart.cancelListingRoot, (rootDigest)));
        (nonceCallSucceeded,) = address(cart).call(abi.encodeCall(Cart.invalidateListingNonce, ()));
        return this.onERC721Received.selector;
    }
}

contract ReentrantFulfillmentReceiver {
    Cart internal immutable cart;

    bytes internal reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(Cart cart_) {
        cart = cart_;
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _attemptReentry();
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        _attemptReentry();
        return this.onERC1155Received.selector;
    }

    function _attemptReentry() private {
        if (reentryData.length == 0) return;
        reentryAttempted = true;
        (reentrySucceeded,) = address(cart).call(reentryData);
    }
}

contract CartTest is Test {
    uint256 internal constant PLATFORM_PK = 0xA11CE;
    uint256 internal constant SELLER_PK = 0xB0B;
    uint256 internal constant PAYER_PK = 0xC0FFEE;

    address internal platformSigner;
    address internal seller;
    address internal payer;
    address internal sellerPayout = address(0x5001);
    address internal collector = address(0x5002);

    Cart internal cart;
    CartHashes internal hashes;
    CartRoutePolicy internal routePolicy;
    CartPayments internal paymentExecutor;
    CartTestWETH internal weth;
    CartTestRouter internal router;
    CartTestPermit2 internal permit2;

    function setUp() public {
        platformSigner = vm.addr(PLATFORM_PK);
        seller = vm.addr(SELLER_PK);
        payer = vm.addr(PAYER_PK);
        weth = new CartTestWETH();
        router = new CartTestRouter();
        permit2 = new CartTestPermit2();
        hashes = new CartHashes();
        routePolicy = new CartRoutePolicy();
        paymentExecutor = new CartPayments(address(routePolicy));

        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData = abi.encodeCall(
            Cart.initialize, (address(this), platformSigner, address(router), address(permit2), address(weth))
        );
        cart = Cart(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function testAtomicNativeOffchainLineCapturesProtocolSpread() public {
        ICart.Listing memory listing =
            _listing(keccak256("offchain-listing"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingHash: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("native-offchain", lines, routes, actions);
        order.paymentAmount = 1.25 ether;
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        uint256 sourceBefore = payer.balance;
        uint256 protocolBefore = address(this).balance;

        vm.prank(payer);
        cart.executePurchase{value: 1.25 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(sellerPayout.balance, 1 ether);
        assertEq(payer.balance, sourceBefore - 1.25 ether);
        assertEq(address(this).balance, protocolBefore + 0.25 ether);
    }

    function testZeroListingHashPreservesExplicitFulfillmentKind() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = ICart.OrderLine({
            sku: keccak256("arbitrary-erc20"),
            listingHash: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.CURRENCY_SWAP,
            quantity: 1,
            settlementCurrency: address(weth),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        lines[1] = ICart.OrderLine({
            sku: keccak256("fee"),
            listingHash: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: collector
        });
        ICart.PayoutRoute[] memory routes = _emptyRoutes(2);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("arbitrary-erc20", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        vm.deal(payer, 2 ether);
        vm.recordLogs();
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        bytes32 eventSignature =
            keccak256("OrderLineSettled(bytes32,uint256,bytes32,bytes32,uint256,address,uint256,address,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundSwap;
        bool foundFee;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            (,,,,, ICart.FulfillmentKind kind) =
                abi.decode(logs[i].data, (bytes32, uint256, address, uint256, address, ICart.FulfillmentKind));
            if (logs[i].topics[2] == bytes32(uint256(0))) {
                assertEq(uint8(kind), uint8(ICart.FulfillmentKind.CURRENCY_SWAP));
                foundSwap = true;
            } else if (logs[i].topics[2] == bytes32(uint256(1))) {
                assertEq(uint8(kind), uint8(ICart.FulfillmentKind.NONE));
                foundFee = true;
            }
        }
        assertTrue(foundSwap, "CURRENCY_SWAP settlement not emitted");
        assertTrue(foundFee, "NONE settlement not emitted");
    }

    function testCurrencySwapCannotBeSellerListing() public {
        ICart.Listing memory listing =
            _listing(keccak256("listed-swap"), ICart.FulfillmentKind.CURRENCY_SWAP, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("listed-swap", lines, routes, actions);
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidListing.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testCurrencySwapMustChangeCurrency() public {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: keccak256("same-currency-swap"),
            listingHash: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.CURRENCY_SWAP,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: collector
        });
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("same-currency-swap", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));
        ICart.Listing[] memory listings = new ICart.Listing[](0);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.ListingTermsMismatch.selector, 0));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testRejectsZeroOrderId() public {
        ICart.Listing memory listing =
            _listing(keccak256("zero-order-id-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("zero-order-id", lines, routes, actions);
        order.orderId = bytes32(0);

        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidOrderId.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertFalse(cart.executedOrderIds(bytes32(0)));
    }

    function testUnderfundedNativePurchaseCannotUsePreexistingWeth() public {
        // Keep the synthetic WETH solvent when the purchase attempts to withdraw
        // the pre-existing balance plus the newly deposited payment.
        vm.deal(address(weth), 1 ether);
        weth.mint(address(cart), 1 ether);

        ICart.Listing memory listing =
            _listing(keccak256("no-cart-subsidy"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 2 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("no-cart-subsidy", lines, routes, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.NativeValueMismatch.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(weth.balanceOf(address(cart)), 1 ether);
        assertEq(sellerPayout.balance, 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testSuccessfulPurchasePreservesPreexistingCartBalances() public {
        weth.mint(address(cart), 3 ether);
        vm.deal(address(cart), 2 ether);

        ICart.Listing memory listing =
            _listing(keccak256("preserve-cart-balances"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "preserve-cart-balances", 1, actions);

        assertEq(weth.balanceOf(address(cart)), 3 ether);
        assertEq(address(cart).balance, 2 ether);
    }

    function testFulfillmentReceiverCannotReenterSellerInvalidation() public {
        CartTestERC721 token = new CartTestERC721();
        bytes32 listingSeed = keccak256("reentrant-seller-listing");
        ReentrantSellerReceiver sellerContract = new ReentrantSellerReceiver(cart, bytes32(0));
        token.mint(address(sellerContract), 1);
        sellerContract.approveCart(token, address(cart));

        ICart.Listing memory listing =
            _listing(listingSeed, ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout);
        listing.seller = address(sellerContract);
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: address(sellerContract)});
        ICart.PurchaseOrder memory order = _order("reentrant-seller", lines, routes, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        sellerContract.setRootDigest(hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), authorization.listingRoots[0]));
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertFalse(sellerContract.cancelRootCallSucceeded());
        assertFalse(sellerContract.nonceCallSucceeded());
        assertEq(cart.listingNonces(address(sellerContract)), 0);
    }

    function testErc721ReceiverCannotReenterPurchase() public {
        CartTestERC721 token = new CartTestERC721();
        ReentrantFulfillmentReceiver receiver = new ReentrantFulfillmentReceiver(cart);
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listing(
            keccak256("reentrant-721-purchase"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: address(receiver)});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-721-purchase", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        receiver.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                _combineRoutes(routes),
                actions,
                platformSignature,
                1 ether
            )
        );

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(token.ownerOf(1), address(receiver));
    }

    function testErc1155ReceiverCannotReenterPurchase() public {
        CartTestERC1155 token = new CartTestERC1155();
        ReentrantFulfillmentReceiver receiver = new ReentrantFulfillmentReceiver(cart);
        token.mint(seller, 42, 2);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("reentrant-1155-purchase"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            2
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: address(receiver)});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-1155-purchase", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        receiver.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                _combineRoutes(routes),
                actions,
                platformSignature,
                2 ether
            )
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertEq(token.balanceOf(address(receiver), 42), 2);
    }

    function testErc721TokenCannotReenterPurchase() public {
        ReentrantERC721 token = new ReentrantERC721(cart);
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listing(
            keccak256("reentrant-721-token"), ICart.FulfillmentKind.ERC721_TRANSFER, address(token), 1, sellerPayout
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-721-token", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        token.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                _combineRoutes(routes),
                actions,
                platformSignature,
                1 ether
            )
        );

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(token.ownerOf(1), collector);
    }

    function testErc1155TokenCannotReenterPurchase() public {
        ReentrantERC1155 token = new ReentrantERC1155(cart);
        token.mint(seller, 42, 2);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("reentrant-1155-token"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            2
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory listings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("reentrant-1155-token", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        token.setReentryData(
            abi.encodeWithSelector(
                Cart.executePurchase.selector,
                order,
                lines,
                listings,
                authorization,
                _combineRoutes(routes),
                actions,
                platformSignature,
                2 ether
            )
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertEq(token.balanceOf(collector, 42), 2);
    }

    function testUniversalRouterSubsidyBecomesProtocolSpread() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("router-subsidy");
        outputToken.mint(address(router), 1 ether);
        router.configure(address(outputToken), 1 ether, 0, true);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute[] memory routes) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("router-subsidy", lines, routes, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 1 ether);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
    }

    function testUniversalRouterConsumesPermit2InputAndCapturesExactOutputSpread() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("permit2-exact-output");

        address inputSink = address(0x6001);
        router.configureSettlement(
            address(permit2), inputSink, address(inputToken), address(outputToken), 1 ether, 1 ether
        );
        outputToken.mint(address(router), 1 ether);

        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = address(outputToken);
        ICart.PayoutRoute[] memory routes = new ICart.PayoutRoute[](1);
        address[] memory path = new address[](2);
        path[0] = address(inputToken);
        path[1] = address(outputToken);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1.25 ether, path, true);
        routes[0] = ICart.PayoutRoute({commands: hex"09", inputs: inputs, routerValue: 0});

        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("permit2-exact-output", lines, routes, actions);
        order.paymentCurrency = address(inputToken);
        order.paymentAmount = 1.25 ether;
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1.25 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1.25 ether);

        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        // The router spent 1 token through Permit2 and Cart captured the unused 0.25-token
        // fixed-quote spread for the protocol.
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 0.25 ether);
        assertEq(inputToken.balanceOf(inputSink), 1 ether);
        assertEq(inputToken.balanceOf(address(cart)), 0);
        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(router)), 0);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(cart), address(inputToken), address(router));
        assertEq(permitAmount, 0);
        assertTrue(cart.executedOrderIds(order.orderId));
    }

    function testOrderLineSettledReportsActualPaymentAndFulfillmentKind() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("authoritative-settlement-event");
        router.configure(address(outputToken), 2 ether, 0, false);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute[] memory routes) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("authoritative-settlement-event", lines, routes, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.recordLogs();
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        bytes32 eventSignature =
            keccak256("OrderLineSettled(bytes32,uint256,bytes32,bytes32,uint256,address,uint256,address,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            assertEq(logs[i].topics[1], order.orderId);
            assertEq(logs[i].topics[2], bytes32(uint256(0)));
            assertEq(logs[i].topics[3], listing.sku);
            assertEq(
                logs[i].data,
                abi.encode(
                    _listingDigest(listing),
                    uint256(1),
                    address(outputToken),
                    uint256(1 ether),
                    sellerPayout,
                    ICart.FulfillmentKind.NONE
                )
            );
            found = true;
        }
        assertTrue(found, "OrderLineSettled not emitted");
    }

    function testOrderWideRouteSupportsMultipleOutputsAndSendsSurplusToProtocol() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputA = new CartTestToken("Output A", "OA");
        CartTestToken outputB = new CartTestToken("Output B", "OB");

        ICart.Listing memory listingA =
            _listing(keccak256("order-wide-a"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingA.settlementCurrency = address(outputA);
        ICart.Listing memory listingB =
            _listing(keccak256("order-wide-b"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingB.settlementCurrency = address(outputB);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listingA;
        listings[1] = listingB;

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listingA, 1, 1 ether)[0];
        lines[1] = _lineForListing(listingB, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(outputA);
        lines[1].settlementCurrency = address(outputB);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputA), address(outputB), 0.5 ether, 0.5 ether, false);
        address[] memory tokens = new address[](2);
        tokens[0] = address(outputA);
        tokens[1] = address(outputB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 3 ether;
        router.configureMulti(tokens, amounts);

        ICart.PurchaseOrder memory order = _orderSingle("order-wide-multi-output", inputToken, lines, route, 1 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(outputA.balanceOf(sellerPayout), 1 ether);
        assertEq(outputB.balanceOf(sellerPayout), 1 ether);
        assertEq(outputA.balanceOf(address(this)), 1 ether);
        assertEq(outputB.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.balanceOf(address(this)), 1 ether);
        assertEq(router.executeCalls(), 1);
        assertEq(inputToken.balanceOf(payer), 0);
    }

    function testOrderWideRouteSupportsMixedDirectAndSwapLines() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputToken = new CartTestToken("Output", "OUT");

        ICart.Listing memory directListing =
            _listing(keccak256("order-wide-direct"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        directListing.settlementCurrency = address(inputToken);
        ICart.Listing memory swapListing =
            _listing(keccak256("order-wide-swap"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        swapListing.settlementCurrency = address(outputToken);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = directListing;
        listings[1] = swapListing;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(directListing, 1, 1 ether)[0];
        lines[1] = _lineForListing(swapListing, 1, 2 ether)[0];
        lines[0].settlementCurrency = address(inputToken);
        lines[1].settlementCurrency = address(outputToken);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputToken), address(0), 2 ether, 0, false);
        address[] memory tokens = new address[](1);
        tokens[0] = address(outputToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3 ether;
        router.configureMulti(tokens, amounts);
        ICart.PurchaseOrder memory order = _orderSingle("order-wide-mixed", inputToken, lines, route, 3 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 3 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 3 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(inputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(sellerPayout), 2 ether);
        assertEq(outputToken.balanceOf(address(this)), 1 ether);
        assertEq(inputToken.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.balanceOf(payer), 0);
    }

    function testOrderWideExactOutputRouteCapturesUnusedInputAsProtocolSpread() public {
        CartTestToken inputToken = new CartTestToken("Input", "IN");
        CartTestToken outputA = new CartTestToken("Output A", "OA");
        CartTestToken outputB = new CartTestToken("Output B", "OB");
        ICart.Listing memory listingA =
            _listing(keccak256("order-wide-exact-a"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingA.settlementCurrency = address(outputA);
        ICart.Listing memory listingB =
            _listing(keccak256("order-wide-exact-b"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listingB.settlementCurrency = address(outputB);
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = listingA;
        listings[1] = listingB;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listingA, 1, 1 ether)[0];
        lines[1] = _lineForListing(listingB, 1, 1 ether)[0];
        lines[0].settlementCurrency = address(outputA);
        lines[1].settlementCurrency = address(outputB);
        ICart.PayoutRoute memory route =
            _multiOutputRoute(address(inputToken), address(outputA), address(outputB), 1 ether, 1 ether, true);
        address[] memory tokens = new address[](2);
        tokens[0] = address(outputA);
        tokens[1] = address(outputB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        router.configureMulti(tokens, amounts);
        ICart.PurchaseOrder memory order = _orderSingle("order-wide-exact-output", inputToken, lines, route, 2 ether);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        inputToken.mint(payer, 2 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 2 ether);

        vm.prank(payer);
        cart.executePurchase(order, lines, listings, authorization, route, new ICart.FulfillmentAction[](0), signature);

        assertEq(outputA.balanceOf(sellerPayout), 1 ether);
        assertEq(outputB.balanceOf(sellerPayout), 1 ether);
        assertEq(inputToken.balanceOf(payer), 0);
        assertEq(inputToken.balanceOf(address(this)), 2 ether);
        assertEq(inputToken.allowance(address(cart), address(permit2)), 0);
    }

    function testIncidentalUniversalRouterTokenBalanceDoesNotBlockSettlement() public {
        (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing) =
            _routedTokensAndListing("router-retention");
        router.configure(address(outputToken), 1 ether, 1 ether, false);

        (ICart.OrderLine[] memory lines, ICart.PayoutRoute[] memory routes) =
            _routedLineAndRoute(listing, address(inputToken), address(outputToken));
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("router-retention", lines, routes, actions);
        order.paymentCurrency = address(inputToken);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        inputToken.mint(payer, 1 ether);
        vm.prank(payer);
        inputToken.approve(address(cart), 1 ether);
        vm.prank(payer);
        cart.executePurchase(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(outputToken.balanceOf(address(router)), 1 ether);
        assertEq(outputToken.balanceOf(sellerPayout), 1 ether);
        assertEq(outputToken.balanceOf(address(cart)), 0);
    }

    function testAtomicNftFulfillmentRollsBackOnPayoutFailure() public {
        CartTestERC721 token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        RevertingPayoutRecipient revertingRecipient = new RevertingPayoutRecipient();

        ICart.Listing memory listing = _listing(
            keccak256("nft-listing"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(token),
            1,
            address(revertingRecipient)
        );
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingHash: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: address(revertingRecipient)
        });
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("nft-rollback", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, bytes("")));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(token.ownerOf(1), seller);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(order.orderId));
    }

    function testSellerNonceInvalidationRejectsPreviouslySignedListing() public {
        ICart.Listing memory listing =
            _listing(keccak256("invalidated-listing"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingHash: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: sellerPayout
        });
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("invalidated", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.prank(seller);
        cart.invalidateListingNonce();

        vm.deal(payer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICart.InvalidListingNonce.selector, 1, 0));
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function testErc1155TransferFulfillsRequestedQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 3);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("1155-transfer"), ICart.FulfillmentKind.ERC1155_TRANSFER, address(token), 42, sellerPayout, 3
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("1155-transfer-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(token.balanceOf(collector, 42), 2);
        assertEq(token.balanceOf(seller, 42), 1);
    }

    function testErc1155MintToFulfillsQuantity() public {
        CartTestERC1155 token = new CartTestERC1155();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("1155-mint"), ICart.FulfillmentKind.ERC1155_MINT_TO, address(token), 7, sellerPayout, 3
        );
        ICart.OrderLine[] memory lines = _lineForListing(listing, 2, 2 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("1155-mint-order", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        cart.executePurchase{value: 2 ether}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );

        assertEq(token.balanceOf(collector, 7), 2);
    }

    function testUncappedOffchainListingCanBeFilledRepeatedly() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-offchain"), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "uncapped-offchain-one", 1, actions);
        _executeNativeListing(listing, "uncapped-offchain-two", 2, actions);

        assertEq(cart.filledQuantity(_listingDigest(listing)), 3);
    }

    function testUncappedNoneListingCanBeFilledRepeatedly() public {
        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-none"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        _executeNativeListing(listing, "uncapped-none-one", 1, actions);
        _executeNativeListing(listing, "uncapped-none-two", 1, actions);

        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc721TransferCanReviveWhenTokenReturns() public {
        CartTestERC721 token = new CartTestERC721();
        token.mint(seller, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-721-transfer"),
            ICart.FulfillmentKind.ERC721_TRANSFER,
            address(token),
            1,
            sellerPayout,
            0
        );

        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        _executeNativeListing(listing, "uncapped-721-first", 1, actions);
        assertEq(token.ownerOf(1), collector);

        ICart.OrderLine[] memory unavailableLines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory unavailableRoutes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory unavailableActions = new ICart.FulfillmentAction[](1);
        unavailableActions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.PurchaseOrder memory unavailableOrder =
            _order("uncapped-721-unavailable", unavailableLines, unavailableRoutes, unavailableActions);
        bytes memory unavailablePlatformSignature = _sign(PLATFORM_PK, _orderDigest(unavailableOrder));
        ICart.Listing[] memory unavailableListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory unavailableAuthorization =
            _rootAuthorization(unavailableListings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                uint256(0),
                uint256(0),
                abi.encodeWithSignature("Error(string)", "ERC721: caller is not token owner or approved")
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            unavailableOrder,
            unavailableLines,
            unavailableListings,
            unavailableAuthorization,
            _combineRoutes(unavailableRoutes),
            unavailableActions,
            unavailablePlatformSignature
        );

        vm.prank(collector);
        token.safeTransferFrom(collector, seller, 1);
        _executeNativeListing(listing, "uncapped-721-returned", 1, actions);

        assertEq(token.ownerOf(1), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc1155TransferCanReviveWhenBalanceReturns() public {
        CartTestERC1155 token = new CartTestERC1155();
        token.mint(seller, 42, 1);
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-1155-transfer"),
            ICart.FulfillmentKind.ERC1155_TRANSFER,
            address(token),
            42,
            sellerPayout,
            0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        _executeNativeListing(listing, "uncapped-1155-first", 1, actions);
        assertEq(token.balanceOf(seller, 42), 0);

        ICart.OrderLine[] memory unavailableLines = _lineForListing(listing, 1, 1 ether);
        ICart.PayoutRoute[] memory unavailableRoutes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory unavailableActions = new ICart.FulfillmentAction[](1);
        unavailableActions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});
        ICart.PurchaseOrder memory unavailableOrder =
            _order("uncapped-1155-unavailable", unavailableLines, unavailableRoutes, unavailableActions);
        bytes memory unavailablePlatformSignature = _sign(PLATFORM_PK, _orderDigest(unavailableOrder));
        ICart.Listing[] memory unavailableListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory unavailableAuthorization =
            _rootAuthorization(unavailableListings, SELLER_PK);

        vm.deal(payer, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                uint256(0),
                uint256(0),
                abi.encodeWithSignature("Error(string)", "ERC1155: insufficient balance for transfer")
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            unavailableOrder,
            unavailableLines,
            unavailableListings,
            unavailableAuthorization,
            _combineRoutes(unavailableRoutes),
            unavailableActions,
            unavailablePlatformSignature
        );

        vm.prank(collector);
        token.safeTransferFrom(collector, seller, 42, 1, "");
        _executeNativeListing(listing, "uncapped-1155-returned", 1, actions);

        assertEq(token.balanceOf(seller, 42), 0);
        assertEq(token.balanceOf(collector, 42), 1);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testUncappedErc1155MintToDoesNotUseFilledQuantityAsLimit() public {
        CartTestERC1155 token = new CartTestERC1155();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-1155-mint"), ICart.FulfillmentKind.ERC1155_MINT_TO, address(token), 7, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});

        _executeNativeListing(listing, "uncapped-1155-mint-one", 2, actions);
        _executeNativeListing(listing, "uncapped-1155-mint-two", 2, actions);

        assertEq(token.balanceOf(collector, 7), 4);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 4);
    }

    function testUncappedErc721MintToDoesNotUseFilledQuantityAsLimit() public {
        CartTestMintableERC721 token = new CartTestMintableERC721();
        vm.prank(address(this));
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("uncapped-721-mint"), ICart.FulfillmentKind.ERC721_MINT_TO, address(token), 0, sellerPayout, 0
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 1, recipient: collector});

        _executeNativeListing(listing, "uncapped-721-mint-one", 1, actions);
        _executeNativeListing(listing, "uncapped-721-mint-two", 1, actions);

        assertEq(token.ownerOf(1), collector);
        assertEq(token.ownerOf(2), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testFulfillmentEventsIdentifyEveryMintedToken() public {
        CartTestMintableERC721 token = new CartTestMintableERC721();
        token.transferOwnership(seller);
        vm.prank(seller);
        token.setMinter(address(cart), true);

        ICart.Listing memory listing = _listingWithQuantity(
            keccak256("authoritative-mint-events"),
            ICart.FulfillmentKind.ERC721_MINT_TO,
            address(token),
            0,
            sellerPayout,
            2
        );
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction({lineIndex: 0, quantity: 2, recipient: collector});

        vm.recordLogs();
        _executeNativeListing(listing, "authoritative-mint-events", 2, actions);

        bytes32 eventSignature = keccak256(
            "FulfillmentActionExecuted(bytes32,uint256,uint256,uint8,address,address,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 eventCount;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(cart) || logs[i].topics[0] != eventSignature) continue;
            assertEq(logs[i].topics[1], keccak256("authoritative-mint-events"));
            assertEq(logs[i].topics[2], bytes32(uint256(0)));
            assertEq(logs[i].topics[3], bytes32(uint256(0)));
            assertEq(
                logs[i].data,
                abi.encode(
                    ICart.FulfillmentKind.ERC721_MINT_TO,
                    address(token),
                    collector,
                    uint256(1),
                    eventCount + 1,
                    eventCount
                )
            );
            ++eventCount;
        }
        assertEq(eventCount, 2);
    }

    function testTooManyListingsAreRejectedBeforeVerification() public {
        ICart.Listing memory referencedListing =
            _listing(keccak256("referenced"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        ICart.Listing memory strayListing =
            _listing(keccak256("stray"), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);

        ICart.OrderLine[] memory lines = _lineForListing(referencedListing, 1, 1 ether);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);

        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = referencedListing;
        listings[1] = strayListing;
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);

        ICart.PurchaseOrder memory order = _order("stray-listing", lines, routes, actions);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, 1 ether);
        vm.expectRevert(ICart.InvalidArrayLength.selector);
        vm.prank(payer);
        cart.executePurchase{value: 1 ether}(
            order, lines, listings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function _listing(
        bytes32 listingSeed,
        ICart.FulfillmentKind fulfillmentKind,
        address tokenContract,
        uint256 tokenId,
        address paymentRecipient
    ) internal view returns (ICart.Listing memory) {
        return _listingWithQuantity(listingSeed, fulfillmentKind, tokenContract, tokenId, paymentRecipient, 1);
    }

    function _listingWithQuantity(
        bytes32 listingSeed,
        ICart.FulfillmentKind fulfillmentKind,
        address tokenContract,
        uint256 tokenId,
        address paymentRecipient,
        uint256 availableQuantity
    ) internal view returns (ICart.Listing memory) {
        return ICart.Listing({
            listingId: listingSeed,
            seller: seller,
            sku: keccak256(abi.encodePacked("sku-", listingSeed)),
            fulfillmentKind: fulfillmentKind,
            tokenContract: tokenContract,
            tokenId: tokenId,
            settlementCurrency: address(0),
            minimumUnitPrice: 1 ether,
            availableQuantity: availableQuantity,
            paymentRecipient: paymentRecipient
        });
    }

    function _lineForListing(ICart.Listing memory listing, uint256 quantity, uint256 amount)
        internal
        view
        returns (ICart.OrderLine[] memory lines)
    {
        lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: listing.sku,
            listingHash: _listingDigest(listing),
            fulfillmentKind: listing.fulfillmentKind,
            quantity: quantity,
            settlementCurrency: address(0),
            amount: amount,
            paymentRecipient: listing.paymentRecipient
        });
    }

    function _executeNativeListing(
        ICart.Listing memory listing,
        string memory orderId,
        uint256 quantity,
        ICart.FulfillmentAction[] memory actions
    ) internal {
        uint256 amount = listing.minimumUnitPrice * quantity;
        ICart.OrderLine[] memory lines = _lineForListing(listing, quantity, amount);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.PurchaseOrder memory order = _order(orderId, lines, routes, actions);
        ICart.Listing[] memory authorizationListings = _singletonListing(listing);
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(authorizationListings, SELLER_PK);
        bytes memory platformSignature = _sign(PLATFORM_PK, _orderDigest(order));

        vm.deal(payer, amount);
        vm.prank(payer);
        cart.executePurchase{value: amount}(
            order, lines, authorizationListings, authorization, _combineRoutes(routes), actions, platformSignature
        );
    }

    function _order(
        string memory id,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute[] memory routes,
        ICart.FulfillmentAction[] memory actions
    ) internal view returns (ICart.PurchaseOrder memory) {
        uint256 paymentAmount;
        for (uint256 i = 0; i < lines.length; ++i) {
            paymentAmount += lines[i].amount;
        }
        return ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(0),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(_combineRoutes(routes)),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
    }

    function _orderSingle(
        string memory id,
        CartTestToken inputToken,
        ICart.OrderLine[] memory lines,
        ICart.PayoutRoute memory route,
        uint256 paymentAmount
    ) internal view returns (ICart.PurchaseOrder memory) {
        return ICart.PurchaseOrder({
            orderId: keccak256(bytes(id)),
            paymentCurrency: address(inputToken),
            deadline: block.timestamp + 1 days,
            paymentAmount: paymentAmount,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(new ICart.FulfillmentAction[](0))
        });
    }

    function _multiOutputRoute(
        address inputToken,
        address outputA,
        address outputB,
        uint256 amountA,
        uint256 amountB,
        bool exactOutput
    ) internal pure returns (ICart.PayoutRoute memory route) {
        uint256 count = amountB == 0 ? 1 : 2;
        route.commands = new bytes(count);
        route.inputs = new bytes[](count);
        route.commands[0] = exactOutput ? bytes1(0x09) : bytes1(0x08);
        address[] memory pathA = new address[](2);
        pathA[0] = inputToken;
        pathA[1] = outputA;
        route.inputs[0] = abi.encode(address(1), amountA, amountA, pathA, true);
        if (count == 2) {
            route.commands[1] = exactOutput ? bytes1(0x09) : bytes1(0x08);
            address[] memory pathB = new address[](2);
            pathB[0] = inputToken;
            pathB[1] = outputB;
            route.inputs[1] = abi.encode(address(1), amountB, amountB, pathB, true);
        }
    }

    function _routedTokensAndListing(string memory id)
        internal
        returns (CartTestToken inputToken, CartTestToken outputToken, ICart.Listing memory listing)
    {
        inputToken = new CartTestToken("Input", "IN");
        outputToken = new CartTestToken("Output", "OUT");
        listing = _listing(keccak256(bytes(id)), ICart.FulfillmentKind.NONE, address(0), 0, sellerPayout);
        listing.settlementCurrency = address(outputToken);
    }

    function _routedLineAndRoute(ICart.Listing memory listing, address inputToken, address outputToken)
        internal
        view
        returns (ICart.OrderLine[] memory lines, ICart.PayoutRoute[] memory routes)
    {
        lines = _lineForListing(listing, 1, 1 ether);
        lines[0].settlementCurrency = outputToken;
        routes = new ICart.PayoutRoute[](1);
        address[] memory path = new address[](2);
        path[0] = inputToken;
        path[1] = outputToken;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        routes[0] = ICart.PayoutRoute({commands: hex"08", inputs: inputs, routerValue: 0});
    }

    function _listingDigest(ICart.Listing memory listing) internal view returns (bytes32) {
        return hashes.hashListing(cart.DOMAIN_SEPARATOR(), listing);
    }

    function _orderDigest(ICart.PurchaseOrder memory order) internal view returns (bytes32) {
        return hashes.hashOrder(cart.DOMAIN_SEPARATOR(), order);
    }

    function _emptyRoutes(uint256 count) internal pure returns (ICart.PayoutRoute[] memory routes) {
        routes = new ICart.PayoutRoute[](count);
        for (uint256 i = 0; i < count; ++i) {
            routes[i] = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0), routerValue: 0});
        }
    }

    function _combineRoutes(ICart.PayoutRoute[] memory routes) internal pure returns (ICart.PayoutRoute memory route) {
        uint256 commandLength;
        uint256 inputCount;
        for (uint256 i = 0; i < routes.length; ++i) {
            commandLength += routes[i].commands.length;
            inputCount += routes[i].inputs.length;
            route.routerValue += routes[i].routerValue;
        }
        route.commands = new bytes(commandLength);
        route.inputs = new bytes[](inputCount);
        uint256 commandOffset;
        uint256 inputOffset;
        for (uint256 i = 0; i < routes.length; ++i) {
            for (uint256 j = 0; j < routes[i].commands.length; ++j) {
                route.commands[commandOffset++] = routes[i].commands[j];
            }
            for (uint256 j = 0; j < routes[i].inputs.length; ++j) {
                route.inputs[inputOffset++] = routes[i].inputs[j];
            }
        }
    }

    function _singletonListing(ICart.Listing memory listing) internal pure returns (ICart.Listing[] memory listings) {
        listings = new ICart.Listing[](1);
        listings[0] = listing;
    }

    function _rootAuthorization(ICart.Listing[] memory listings, uint256 sellerPk)
        internal
        returns (ICart.ListingPurchaseAuthorization memory authorization)
    {
        authorization.listingRoots = new ICart.ListingRoot[](listings.length);
        authorization.listingRootSignatures = new bytes[](listings.length);
        authorization.listingRootIndexes = new uint256[](listings.length);
        authorization.listingProofs = new bytes32[][](listings.length);
        for (uint256 i = 0; i < listings.length; ++i) {
            ICart.Listing memory listing = listings[i];
            ICart.ListingRoot memory root = ICart.ListingRoot({
                listingsRoot: hashes.hashListingLeaf(_listingDigest(listing)),
                nonce: 0,
                deadline: block.timestamp + 1 days
            });
            authorization.listingRoots[i] = root;
            authorization.listingRootSignatures[i] =
                _sign(sellerPk, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), root));
            authorization.listingRootIndexes[i] = i;
            authorization.listingProofs[i] = new bytes32[](0);
        }
    }

    function _singletonBytes(bytes memory value) internal pure returns (bytes[] memory values) {
        values = new bytes[](1);
        values[0] = value;
    }

    function _sign(uint256 privateKey, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}
