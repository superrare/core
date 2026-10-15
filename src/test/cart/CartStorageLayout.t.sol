// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Cart} from "../../cart/Cart.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {CartTestPermit2, CartTestRouter, CartTestWETH} from "./Cart.t.sol";

/// @dev Test-only implementation used to prove that a compatible UUPS upgrade preserves all
///      Cart-owned namespaced state.
contract CartStorageLayoutCanary is Cart {
    constructor(address routePolicy_, address paymentExecutor_) Cart(routePolicy_, paymentExecutor_) {}

    function storageLayoutCanary() external pure returns (bytes32) {
        return keccak256("CartStorageLayoutCanary");
    }
}

contract CartStorageLayoutTest is Test {
    using stdJson for string;

    string internal constant STORAGE_LAYOUT_PATH = "src/cart/Cart.storage-layout.json";

    Cart internal cart;
    CartRoutePolicy internal routePolicy;
    CartPayments internal paymentExecutor;
    CartTestWETH internal weth;
    CartTestRouter internal router;
    CartTestPermit2 internal permit2;

    address internal platformSigner = address(0x1001);
    address internal seller = address(0x1002);

    function setUp() public {
        weth = new CartTestWETH();
        router = new CartTestRouter();
        permit2 = new CartTestPermit2();
        routePolicy = new CartRoutePolicy();
        paymentExecutor = new CartPayments(address(routePolicy));

        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData = abi.encodeCall(
            Cart.initialize, (address(this), platformSigner, address(router), address(permit2), address(weth))
        );
        cart = Cart(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function testStorageLayoutBaselinePreservesProxyState() public {
        string memory layout = vm.readFile(STORAGE_LAYOUT_PATH);
        assertEq(layout.readString(".storageModel"), "erc7201");
        assertEq(layout.readString(".namespaces.config.identifier"), "superrare.storage.CartConfig");
        assertEq(layout.readString(".namespaces.listings.identifier"), "superrare.storage.CartListings");
        assertEq(layout.readString(".namespaces.settlement.identifier"), "superrare.storage.CartSettlement");

        bytes32 configLocation = layout.readBytes32(".namespaces.config.location");
        bytes32 listingsLocation = layout.readBytes32(".namespaces.listings.location");
        bytes32 settlementLocation = layout.readBytes32(".namespaces.settlement.location");
        bytes32 domainSeparator = cart.DOMAIN_SEPARATOR();
        assertEq(cart.owner(), address(this));

        _assertAddressField(layout, configLocation, "config", 0, platformSigner);
        _assertAddressField(layout, configLocation, "config", 1, address(router));
        _assertAddressField(layout, configLocation, "config", 2, address(permit2));
        _assertAddressField(layout, configLocation, "config", 3, address(weth));

        bytes32 orderId = keccak256("layout-order");
        bytes32 listingDigest = keccak256("layout-listing-digest");
        bytes32 rootDigest = keccak256("layout-root-digest");

        vm.store(
            address(cart),
            _mappingSlot(orderId, _fieldSlot(layout, settlementLocation, "settlement", 0)),
            bytes32(uint256(1))
        );
        vm.store(
            address(cart),
            _mappingSlot(listingDigest, _fieldSlot(layout, listingsLocation, "listings", 0)),
            bytes32(uint256(7))
        );

        vm.prank(seller);
        cart.cancelListingRoot(rootDigest);
        vm.prank(seller);
        cart.invalidateListingNonce();
        cart.setPaused(true);

        _assertBoolField(layout, configLocation, "config", 4, true);
        _assertAddressField(layout, configLocation, "config", 5, address(this));
        assertTrue(cart.executedOrderIds(orderId));
        assertEq(cart.filledQuantity(listingDigest), 7);
        assertEq(
            vm.load(address(cart), _mappingSlot(listingDigest, _fieldSlot(layout, listingsLocation, "listings", 0))),
            bytes32(uint256(7))
        );
        assertTrue(cart.cancelledListingRoots(seller, rootDigest));
        assertEq(cart.listingNonces(seller), 1);

        CartStorageLayoutCanary canary = new CartStorageLayoutCanary(address(routePolicy), address(paymentExecutor));
        cart.upgradeTo(address(canary));

        assertEq(
            CartStorageLayoutCanary(payable(address(cart))).storageLayoutCanary(), keccak256("CartStorageLayoutCanary")
        );
        assertEq(cart.platformSigner(), platformSigner);
        assertEq(cart.universalRouter(), address(router));
        assertEq(cart.permit2(), address(permit2));
        assertEq(cart.weth(), address(weth));
        assertEq(cart.owner(), address(this));
        assertEq(cart.protocolRecipient(), address(this));
        assertEq(cart.DOMAIN_SEPARATOR(), domainSeparator);
        assertTrue(cart.paused());
        assertTrue(cart.executedOrderIds(orderId));
        assertEq(cart.filledQuantity(listingDigest), 7);
        assertEq(
            vm.load(address(cart), _mappingSlot(listingDigest, _fieldSlot(layout, listingsLocation, "listings", 0))),
            bytes32(uint256(7))
        );
        assertTrue(cart.cancelledListingRoots(seller, rootDigest));
        assertEq(cart.listingNonces(seller), 1);
    }

    function _assertAddressField(
        string memory layout,
        bytes32 namespaceLocation,
        string memory namespaceName,
        uint256 fieldIndex,
        address expected
    ) internal {
        bytes32 slot = _fieldSlot(layout, namespaceLocation, namespaceName, fieldIndex);
        uint256 offset = layout.readUint(
            string.concat(".namespaces.", namespaceName, ".fields[", vm.toString(fieldIndex), "].offset")
        );
        assertEq(address(uint160(uint256(vm.load(address(cart), slot)) >> (offset * 8))), expected);
    }

    function _assertBoolField(
        string memory layout,
        bytes32 namespaceLocation,
        string memory namespaceName,
        uint256 fieldIndex,
        bool expected
    ) internal {
        bytes32 slot = _fieldSlot(layout, namespaceLocation, namespaceName, fieldIndex);
        uint256 offset = layout.readUint(
            string.concat(".namespaces.", namespaceName, ".fields[", vm.toString(fieldIndex), "].offset")
        );
        bool actual = ((uint256(vm.load(address(cart), slot)) >> (offset * 8)) & 0xff) != 0;
        assertEq(actual, expected);
    }

    function _fieldSlot(
        string memory layout,
        bytes32 namespaceLocation,
        string memory namespaceName,
        uint256 fieldIndex
    ) internal returns (bytes32) {
        uint256 relativeSlot = layout.readUint(
            string.concat(".namespaces.", namespaceName, ".fields[", vm.toString(fieldIndex), "].slot")
        );
        return bytes32(uint256(namespaceLocation) + relativeSlot);
    }

    function _mappingSlot(bytes32 key, bytes32 baseSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, baseSlot));
    }

    function _nestedMappingSlot(address outerKey, bytes32 innerKey, bytes32 baseSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(innerKey, keccak256(abi.encode(outerKey, baseSlot))));
    }
}
