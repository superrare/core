// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Cart} from "../../../../cart/Cart.sol";
import {CartPayments} from "../../../../cart/CartPayments.sol";
import {CartRoutePolicy} from "../../../../cart/CartRoutePolicy.sol";
import {NetworkConfig} from "../../../../../script/NetworkConfig.s.sol";

/// @notice Ethereum Mainnet deployment guard for Cart's immutable external dependencies.
/// @dev This fork test is intentionally outside the default unit-test path. Run it with
///      RPC_URL set to an Ethereum Mainnet endpoint.
contract CartDependencyEthereumTest is Test {
    uint256 private constant ETHEREUM_MAINNET = 1;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));
        require(block.chainid == ETHEREUM_MAINNET, "This test must run on Ethereum Mainnet");
    }

    function testEthereumPinnedDependenciesHaveCodeAndCartAcceptsThem() public {
        NetworkConfig.Addresses memory config = NetworkConfig.get(block.chainid);

        assertEq(config.permit2, PERMIT2);
        assertEq(config.universalRouter, UNIVERSAL_ROUTER);
        assertEq(config.weth, WETH);
        assertEq(NetworkConfig.requireContract(config.permit2, "permit2"), PERMIT2);
        assertEq(NetworkConfig.requireContract(config.universalRouter, "universalRouter"), UNIVERSAL_ROUTER);
        assertEq(NetworkConfig.requireContract(config.weth, "weth"), WETH);
        assertGt(PERMIT2.code.length, 0);
        assertGt(UNIVERSAL_ROUTER.code.length, 0);
        assertGt(WETH.code.length, 0);
        assertTrue(PERMIT2.codehash != bytes32(0));
        assertTrue(UNIVERSAL_ROUTER.codehash != bytes32(0));

        CartRoutePolicy routePolicy = new CartRoutePolicy();
        CartPayments paymentExecutor = new CartPayments(address(routePolicy));
        Cart implementation = new Cart(address(routePolicy), address(paymentExecutor));
        bytes memory initData =
            abi.encodeCall(Cart.initialize, (address(this), address(this), UNIVERSAL_ROUTER, PERMIT2, WETH));
        Cart cart = Cart(payable(address(new ERC1967Proxy(address(implementation), initData))));

        assertEq(cart.permit2(), PERMIT2);
        assertEq(cart.universalRouter(), UNIVERSAL_ROUTER);
        assertEq(cart.weth(), WETH);
    }
}
