// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {Cart} from "../../src/cart/Cart.sol";
import {CartHashes} from "../../src/cart/CartHashes.sol";
import {CartLens} from "../../src/cart/CartLens.sol";
import {CartPayments} from "../../src/cart/CartPayments.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

interface ICartFreeListingUpgradeTarget {
    function owner() external view returns (address);
    function platformSigner() external view returns (address);
    function universalRouter() external view returns (address);
    function permit2() external view returns (address);
    function weth() external view returns (address);
    function paused() external view returns (bool);
    function routePolicy() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title CartFreeListingUpgrade
/// @notice Replaces Cart, CartPayments, CartLens, and CartHashes while preserving the route policy.
/// @dev Cart embeds its payment executor, so the replacement executor and implementation rotate together.
///      No initializer is called. The proxy, approvals, inventory, and order replay state stay in place.
contract CartFreeListingUpgrade is Script {
    error MissingCartProxy();
    error BroadcasterNotCartOwner(address broadcaster, address owner);
    error DependencyMismatch(string dependency, address expected, address actual);
    error ProxyStateChanged(string field);

    struct ProxyState {
        address owner;
        address platformSigner;
        address universalRouter;
        address permit2;
        address weth;
        bytes32 reservedProtocolRecipient;
        bool paused;
        address routePolicy;
        bytes32 domainSeparator;
    }

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();
        address proxyAddress = vm.envOr("CART_PROXY", config.cartProxy);
        if (proxyAddress == address(0) || proxyAddress.code.length == 0) revert MissingCartProxy();

        ICartFreeListingUpgradeTarget proxy = ICartFreeListingUpgradeTarget(proxyAddress);
        ProxyState memory beforeState = _readState(proxy);
        if (beforeState.owner != broadcaster) {
            revert BroadcasterNotCartOwner(broadcaster, beforeState.owner);
        }

        _assertDependency(
            "universalRouter",
            NetworkConfig.requireContract(config.universalRouter, "universalRouter"),
            beforeState.universalRouter
        );
        _assertDependency("permit2", NetworkConfig.requireContract(config.permit2, "permit2"), beforeState.permit2);
        _assertDependency("weth", NetworkConfig.requireContract(config.weth, "weth"), beforeState.weth);
        NetworkConfig.requireContract(beforeState.routePolicy, "cartRoutePolicy");

        vm.startBroadcast(privateKey);

        CartPayments paymentExecutor = new CartPayments(beforeState.routePolicy);
        Cart implementation = new Cart(beforeState.routePolicy, address(paymentExecutor));
        CartLens lens = new CartLens();
        CartHashes hashes = new CartHashes();
        proxy.upgradeToAndCall(address(implementation), bytes(""));

        vm.stopBroadcast();

        _assertStateUnchanged(beforeState, _readState(proxy));

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Cart proxy:", proxyAddress);
        console.log("Cart implementation:", address(implementation));
        console.log("Cart route policy (preserved):", beforeState.routePolicy);
        console.log("Cart payment executor:", address(paymentExecutor));
        console.log("Cart lens:", address(lens));
        console.log("Cart hashes:", address(hashes));
        console.log("Cart owner:", beforeState.owner);
    }

    function _readState(ICartFreeListingUpgradeTarget proxy) private view returns (ProxyState memory state) {
        state.owner = proxy.owner();
        state.platformSigner = proxy.platformSigner();
        state.universalRouter = proxy.universalRouter();
        state.permit2 = proxy.permit2();
        state.weth = proxy.weth();
        // Preserve the retired treasury slot without depending on its removed public getter.
        state.reservedProtocolRecipient = vm.load(
            address(proxy), bytes32(uint256(0xc012b0fbebfe5af5b8d952297ba0e80136c8473aa49759c18a1edebf3f3a9b04))
        );
        state.paused = proxy.paused();
        state.routePolicy = proxy.routePolicy();
        state.domainSeparator = proxy.DOMAIN_SEPARATOR();
    }

    function _assertDependency(string memory dependency, address expected, address actual) private pure {
        if (actual != expected) revert DependencyMismatch(dependency, expected, actual);
    }

    function _assertStateUnchanged(ProxyState memory expected, ProxyState memory actual) private pure {
        if (actual.owner != expected.owner) revert ProxyStateChanged("owner");
        if (actual.platformSigner != expected.platformSigner) revert ProxyStateChanged("platformSigner");
        if (actual.universalRouter != expected.universalRouter) revert ProxyStateChanged("universalRouter");
        if (actual.permit2 != expected.permit2) revert ProxyStateChanged("permit2");
        if (actual.weth != expected.weth) revert ProxyStateChanged("weth");
        if (actual.reservedProtocolRecipient != expected.reservedProtocolRecipient) {
            revert ProxyStateChanged("reservedProtocolRecipient");
        }
        if (actual.paused != expected.paused) revert ProxyStateChanged("paused");
        if (actual.routePolicy != expected.routePolicy) revert ProxyStateChanged("routePolicy");
        if (actual.domainSeparator != expected.domainSeparator) revert ProxyStateChanged("DOMAIN_SEPARATOR");
    }
}
