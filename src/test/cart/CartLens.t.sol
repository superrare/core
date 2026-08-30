// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";

import {CartLens} from "../../cart/CartLens.sol";
import {CartHashes} from "../../cart/CartHashes.sol";
import {ICart} from "../../cart/ICart.sol";
import {ICartLens} from "../../cart/ICartLens.sol";
import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";

contract CartLensTestPolicy is ICartRoutePolicy {
    function validate(bytes calldata, bytes[] calldata) external pure override {}
}

contract CartLensTestSigner {
    bool public valid = true;

    function setValid(bool value) external {
        valid = value;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract CartLensTestState {
    bool public paused;
    address public platformSigner;
    address public routePolicy;
    bytes32 private domainSeparator;

    mapping(bytes32 => bool) public executedOrderIds;
    mapping(bytes32 => uint256) public filledQuantity;
    mapping(address => uint256) public listingNonces;
    mapping(address => mapping(bytes32 => bool)) public cancelledListingRoots;
    mapping(address => mapping(bytes32 => bool)) public cancelledListings;

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return domainSeparator;
    }

    function setConfig(address routePolicy_) external {
        routePolicy = routePolicy_;
    }

    function setSigner(address signer_, bytes32 domainSeparator_) external {
        platformSigner = signer_;
        domainSeparator = domainSeparator_;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setExecuted(bytes32 orderId, bool value) external {
        executedOrderIds[orderId] = value;
    }

    function setNonce(address seller, uint256 nonce) external {
        listingNonces[seller] = nonce;
    }

    function setFilled(bytes32 listingDigest, uint256 quantity) external {
        filledQuantity[listingDigest] = quantity;
    }

    function setCancelled(address seller, bytes32 rootDigest, bool value) external {
        cancelledListingRoots[seller][rootDigest] = value;
    }

    function setListingCancelled(address seller, bytes32 listingDigest, bool value) external {
        cancelledListings[seller][listingDigest] = value;
    }
}

contract CartLensTest is Test {
    CartLens internal lens;
    CartHashes internal hashes;
    CartLensTestState internal cart;
    CartLensTestSigner internal signer;

    address internal constant SELLER = address(0x1001);
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cart-lens-domain");

    function setUp() public {
        lens = new CartLens();
        hashes = new CartHashes();
        cart = new CartLensTestState();
        signer = new CartLensTestSigner();
        cart.setConfig(address(0));
        cart.setSigner(address(signer), DOMAIN_SEPARATOR);
    }

    function testListingStatusUsesRootLifecycleAndDigestCapacity() public {
        ICart.Listing memory listing = _listing(2);
        ICart.ListingRoot memory root = _root(listing);
        cart.setNonce(listing.seller, root.nonce);
        cart.setFilled(_listingDigest(listing), 0);

        ICartLens.ListingStatus memory status = lens.listingStatus(address(cart), listing, root);

        assertEq(status.currentNonce, root.nonce);
        assertEq(status.filledQuantity, 0);
        assertEq(status.remainingQuantity, 2);
        assertTrue(status.nonceValid);
        assertTrue(status.deadlineValid);
        assertTrue(status.active);

        bytes32 rootDigest = _rootDigest(root);
        cart.setCancelled(listing.seller, rootDigest, true);
        status = lens.listingStatus(address(cart), listing, root);
        assertTrue(status.cancelled);
        assertFalse(status.active);
    }

    function testListingStatusUsesMaxQuantityForUncappedListings() public {
        ICart.Listing memory listing = _listing(0);
        ICartLens.ListingStatus memory status = lens.listingStatus(address(cart), listing, _root(listing));

        assertTrue(status.uncapped);
        assertEq(status.remainingQuantity, type(uint256).max);
    }

    function testValidateListingChecksRootSignatureProofAndCapacity() public {
        ICart.Listing memory listing = _listing(2);
        listing.seller = address(signer);
        ICart.ListingRoot memory root = _root(listing);
        bytes32[] memory proof = new bytes32[](0);

        ICartLens.ValidationResult memory result =
            lens.validateListing(address(cart), listing, root, bytes("signature"), proof, 1);
        _assertResult(result, ICartLens.ValidationCode.OK, 0, bytes32(0));

        cart.setFilled(_listingDigest(listing), 2);
        result = lens.validateListing(address(cart), listing, root, bytes("signature"), proof, 1);
        _assertResult(result, ICartLens.ValidationCode.LISTING_QUANTITY_EXCEEDED, 0, _listingDigest(listing));

        signer.setValid(false);
        result = lens.validateListing(address(cart), listing, root, bytes("signature"), proof, 1);
        _assertResult(result, ICartLens.ValidationCode.INVALID_ROOT_SIGNATURE, 0, _rootDigest(root));

        signer.setValid(true);
        ICart.Listing memory other = _listing(2);
        other.sku = keccak256("different-leaf");
        root.listingsRoot = hashes.hashListingLeaf(_listingDigest(other));
        result = lens.validateListing(address(cart), listing, root, bytes("signature"), proof, 1);
        _assertResult(result, ICartLens.ValidationCode.INVALID_MERKLE_PROOF, 0, _listingDigest(listing));
    }

    function testValidateListingRejectsStaleRoot() public {
        ICart.Listing memory listing = _listing(0);
        ICart.ListingRoot memory root = _root(listing);
        root.nonce = 1;
        cart.setNonce(listing.seller, 0);

        ICartLens.ValidationResult memory result =
            lens.validateListing(address(cart), listing, root, bytes("signature"), new bytes32[](0), 1);
        _assertResult(result, ICartLens.ValidationCode.INVALID_LISTING_NONCE, 0, bytes32(0));
    }

    function testValidateListingRejectsOnChainTargetWithoutCode() public {
        ICart.Listing memory listing = _listing(1);
        listing.fulfillmentKind = ICart.FulfillmentKind.ERC1155_TRANSFER;
        listing.tokenContract = address(0xBEEF);
        listing.tokenId = 1;
        ICart.ListingRoot memory root = _root(listing);

        ICartLens.ValidationResult memory result =
            lens.validateListing(address(cart), listing, root, bytes("signature"), new bytes32[](0), 1);

        _assertResult(result, ICartLens.ValidationCode.INVALID_LISTING, 0, bytes32(0));
    }

    function testPreviewRouteAndEnvelopeRemainStateless() public {
        CartLensTestPolicy policy = new CartLensTestPolicy();
        cart.setConfig(address(policy));
        ICart.PayoutRoute memory route = ICart.PayoutRoute({commands: hex"08", inputs: new bytes[](1), routerValue: 0});
        ICartLens.RoutePreview memory preview = lens.previewRoute(address(cart), route);
        assertTrue(preview.valid);
        assertEq(uint8(preview.code), uint8(ICartLens.ValidationCode.OK));
        assertEq(preview.reason.length, 0);

        route.commands = bytes("");
        route.inputs = new bytes[](1);
        preview = lens.previewRoute(address(cart), route);
        assertFalse(preview.valid);
        assertEq(uint8(preview.code), uint8(ICartLens.ValidationCode.ROUTE_REJECTED));
        assertEq(
            preview.reason,
            abi.encodeWithSelector(ICartRoutePolicy.CommandInputLengthMismatch.selector, uint256(0), uint256(1))
        );

        ICart.PurchaseOrder memory order;
        order.orderId = keccak256("lens-order");
        order.deadline = type(uint256).max;
        order.paymentAmount = 1 ether;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = ICart.OrderLine({
            sku: keccak256("lens-sku"),
            listingDigest: bytes32(0),
            fulfillmentKind: ICart.FulfillmentKind.NONE,
            quantity: 1,
            settlementCurrency: address(0),
            amount: 1 ether,
            paymentRecipient: address(0x2001)
        });
        route = ICart.PayoutRoute({commands: bytes(""), inputs: new bytes[](0), routerValue: 0});
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        order.orderLinesHash = hashes.hashOrderLines(lines);
        order.payoutRouteHash = hashes.hashPayoutRoute(route);
        order.fulfillmentActionsHash = hashes.hashFulfillmentActions(actions);

        ICartLens.ValidationResult memory result =
            lens.validatePurchaseEnvelope(address(cart), order, lines, route, actions, bytes("signature"));
        _assertResult(result, ICartLens.ValidationCode.OK, 0, bytes32(0));
    }

    function _listing(uint256 availableQuantity) internal pure returns (ICart.Listing memory listing) {
        listing.listingSalt = keccak256("lens-listing");
        listing.seller = SELLER;
        listing.sku = keccak256("lens-sku");
        listing.fulfillmentKind = ICart.FulfillmentKind.NONE;
        listing.settlementCurrency = address(0);
        listing.minimumUnitPrice = 1 ether;
        listing.availableQuantity = availableQuantity;
        listing.paymentRecipient = address(0x2001);
    }

    function _root(ICart.Listing memory listing) internal view returns (ICart.ListingRoot memory root) {
        root.listingsRoot = hashes.hashListingLeaf(_listingDigest(listing));
        root.nonce = 0;
        root.deadline = block.timestamp + 1 days;
    }

    function _listingDigest(ICart.Listing memory listing) internal view returns (bytes32) {
        return hashes.hashListing(DOMAIN_SEPARATOR, listing);
    }

    function _rootDigest(ICart.ListingRoot memory root) internal view returns (bytes32) {
        return hashes.hashListingRoot(DOMAIN_SEPARATOR, root);
    }

    function _assertResult(
        ICartLens.ValidationResult memory result,
        ICartLens.ValidationCode expectedCode,
        uint256 expectedIndex,
        bytes32 expectedSubject
    ) internal {
        assertEq(result.valid, expectedCode == ICartLens.ValidationCode.OK);
        assertEq(uint8(result.code), uint8(expectedCode));
        assertEq(result.index, expectedIndex);
        assertEq(result.subject, expectedSubject);
    }
}
