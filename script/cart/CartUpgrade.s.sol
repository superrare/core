// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {Cart} from "../../src/cart/Cart.sol";
import {CartLens} from "../../src/cart/CartLens.sol";
import {CartPayments} from "../../src/cart/CartPayments.sol";
import {CartRoutePolicy} from "../../src/cart/CartRoutePolicy.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

interface ICartUpgradeTarget {
    function owner() external view returns (address);
    function universalRouter() external view returns (address);
    function permit2() external view returns (address);
    function weth() external view returns (address);
    function routePolicy() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title CartUpgrade
/// @notice Rotates the implementation and immutable helper contracts behind an existing Cart UUPS proxy.
/// @dev The proxy address and all Cart storage remain stable. The new Cart implementation embeds the
///      newly deployed route policy and payment executor, so those contracts must rotate together.
contract CartUpgrade is Script {
    error MissingCartProxy();
    error BroadcasterNotCartOwner(address broadcaster, address owner);
    error DependencyMismatch(string dependency, address expected, address actual);
    error RoutePolicyRotationFailed(address expected, address actual);

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();
        address proxyAddress = vm.envOr("CART_PROXY", config.cartProxy);
        address weth = NetworkConfig.requireContract(config.weth, "weth");
        address permit2 = NetworkConfig.requireContract(config.permit2, "permit2");
        address universalRouter = NetworkConfig.requireContract(config.universalRouter, "universalRouter");

        if (proxyAddress == address(0) || proxyAddress.code.length == 0) revert MissingCartProxy();

        ICartUpgradeTarget proxy = ICartUpgradeTarget(proxyAddress);
        address owner = proxy.owner();
        if (owner != broadcaster) revert BroadcasterNotCartOwner(broadcaster, owner);

        _assertDependency("universalRouter", universalRouter, proxy.universalRouter());
        _assertDependency("permit2", permit2, proxy.permit2());
        _assertDependency("weth", weth, proxy.weth());

        vm.startBroadcast(privateKey);

        CartRoutePolicy routePolicy = new CartRoutePolicy();
        CartPayments paymentExecutor = new CartPayments(address(routePolicy));
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        CartLens lens = new CartLens();

        proxy.upgradeToAndCall(address(implementation), bytes(""));

        vm.stopBroadcast();

        address rotatedPolicy = proxy.routePolicy();
        if (rotatedPolicy != address(routePolicy)) {
            revert RoutePolicyRotationFailed(address(routePolicy), rotatedPolicy);
        }

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Cart proxy:", proxyAddress);
        console.log("Cart implementation:", address(implementation));
        console.log("Cart route policy:", address(routePolicy));
        console.log("Cart payment executor:", address(paymentExecutor));
        console.log("Cart lens:", address(lens));
        console.log("Cart owner:", owner);
        console.log("Universal Router:", universalRouter);
        console.log("Permit2:", permit2);
        console.log("WETH:", weth);
    }

    function _assertDependency(string memory name, address expected, address actual) private pure {
        if (expected == address(0) || actual != expected) {
            revert DependencyMismatch(name, expected, actual);
        }
    }
}
