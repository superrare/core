// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Cart} from "../../src/cart/Cart.sol";
import {CartPayments} from "../../src/cart/CartPayments.sol";
import {CartRoutePolicy} from "../../src/cart/CartRoutePolicy.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

/// @title CartDeploy
/// @notice Deploys Cart and validates its immutable external settlement dependencies.
/// @dev CART_OWNER defaults to the deployer's address when omitted. Set CART_PLATFORM_SIGNER
///      before broadcasting. Optional code-hash environment variables turn the logged
///      fingerprints into a strict deployment check.
contract CartDeploy is Script {
    error CodeHashMismatch(string name, address target, bytes32 expected, bytes32 actual);

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("CART_OWNER", vm.addr(privateKey));
        address platformSigner = vm.envAddress("CART_PLATFORM_SIGNER");
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();

        address weth = NetworkConfig.requireContract(config.weth, "weth");
        address permit2 = NetworkConfig.requireContract(config.permit2, "permit2");
        address universalRouter = NetworkConfig.requireContract(config.universalRouter, "universalRouter");

        bytes32 expectedPermit2CodeHash = vm.envOr("PERMIT2_CODE_HASH", bytes32(0));
        bytes32 expectedUniversalRouterCodeHash = vm.envOr("UNIVERSAL_ROUTER_CODE_HASH", bytes32(0));
        _checkOptionalCodeHash("permit2", permit2, expectedPermit2CodeHash);
        _checkOptionalCodeHash("universalRouter", universalRouter, expectedUniversalRouterCodeHash);

        vm.startBroadcast(privateKey);

        CartRoutePolicy routePolicy = new CartRoutePolicy();
        CartPayments paymentExecutor = new CartPayments(address(routePolicy));
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData = abi.encodeCall(Cart.initialize, (owner, platformSigner, universalRouter, permit2, weth));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        vm.stopBroadcast();

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Cart proxy:", address(proxy));
        console.log("Cart implementation:", address(implementation));
        console.log("Cart route policy:", address(routePolicy));
        console.log("Cart payment executor:", address(paymentExecutor));
        console.log("WETH:", weth);
        console.log("Permit2:", permit2);
        console.logBytes32(permit2.codehash);
        console.log("Universal Router:", universalRouter);
        console.logBytes32(universalRouter.codehash);
    }

    function _checkOptionalCodeHash(string memory name, address target, bytes32 expected) private view {
        if (expected == bytes32(0)) return;
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(name, target, expected, actual);
    }
}
