// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {Cart} from "../../src/cart/Cart.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

interface ICartImplementationUpgradeTarget {
    function owner() external view returns (address);
    function platformSigner() external view returns (address);
    function universalRouter() external view returns (address);
    function permit2() external view returns (address);
    function weth() external view returns (address);
    function protocolRecipient() external view returns (address);
    function paused() external view returns (bool);
    function routePolicy() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title CartImplementationUpgrade
/// @notice Upgrades only the Cart implementation, preserving existing helpers and settlement dependencies.
/// @dev The payment executor must be the CartPayments address embedded in the current implementation.
///      NetworkConfig supplies it by default; CART_PAYMENT_EXECUTOR may override it. The route policy
///      is read from the proxy. No initializer is called and no Lens or Hashes helpers are deployed.
contract CartImplementationUpgrade is Script {
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
        address protocolRecipient;
        bool paused;
        address routePolicy;
    }

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();
        address proxyAddress = vm.envOr("CART_PROXY", config.cartProxy);
        if (proxyAddress == address(0) || proxyAddress.code.length == 0) revert MissingCartProxy();

        ICartImplementationUpgradeTarget proxy = ICartImplementationUpgradeTarget(proxyAddress);
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
        address paymentExecutor = NetworkConfig.requireContract(
            vm.envOr("CART_PAYMENT_EXECUTOR", config.cartPaymentExecutor), "cartPaymentExecutor"
        );

        vm.startBroadcast(privateKey);

        Cart implementation = new Cart(beforeState.routePolicy, paymentExecutor);
        proxy.upgradeToAndCall(address(implementation), bytes(""));

        vm.stopBroadcast();

        _assertStateUnchanged(beforeState, _readState(proxy));

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Cart proxy:", proxyAddress);
        console.log("Cart implementation:", address(implementation));
        console.log("Cart route policy (preserved):", beforeState.routePolicy);
        console.log("Cart payment executor (preserved):", paymentExecutor);
        console.log("Cart owner:", beforeState.owner);
    }

    function _readState(ICartImplementationUpgradeTarget proxy) private view returns (ProxyState memory state) {
        state.owner = proxy.owner();
        state.platformSigner = proxy.platformSigner();
        state.universalRouter = proxy.universalRouter();
        state.permit2 = proxy.permit2();
        state.weth = proxy.weth();
        state.protocolRecipient = proxy.protocolRecipient();
        state.paused = proxy.paused();
        state.routePolicy = proxy.routePolicy();
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
        if (actual.protocolRecipient != expected.protocolRecipient) revert ProxyStateChanged("protocolRecipient");
        if (actual.paused != expected.paused) revert ProxyStateChanged("paused");
        if (actual.routePolicy != expected.routePolicy) revert ProxyStateChanged("routePolicy");
    }
}
