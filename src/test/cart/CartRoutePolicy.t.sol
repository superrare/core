// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartRoutePolicyFixture} from "./CartRoutePolicyFixture.sol";
import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";

contract CartRoutePolicyTest is CartRoutePolicyFixture {
    function testRejectsWrongSwapRecipient() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](2);
        path[0] = address(0x100);
        path[1] = address(0x200);
        inputs[0] = abi.encode(address(0xbad), 1, 2, path, true);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0xbad)));
        policy.validate(hex"09", inputs);
    }

    function testRejectsWrongRefundRecipient() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0), address(0xbad), 0);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0xbad)));
        policy.validate(hex"04", inputs);
    }

    function testAcceptsCartRefund() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0), address(1), 0);
        address[] memory assets = policy.validate(hex"04", inputs);
        assertEq(assets[0], address(0));
    }

    function testRejectsArbitraryV4Take() public {
        bytes[] memory inputs = new bytes[](1);
        bytes[] memory params = new bytes[](3);
        inputs[0] = abi.encode(hex"080c0e", params);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteInput.selector, 0));
        policy.validate(hex"10", inputs);
    }

    function testAcceptsCompilerV4ActionsAndReportsAssets() public {
        bytes[] memory inputs = new bytes[](1);
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(0), 100);
        params[2] = abi.encode(address(0x200), 50);
        inputs[0] = abi.encode(hex"080c0f", params);
        address[] memory assets = policy.validate(hex"10", inputs);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(0));
        assertEq(assets[1], address(0x200));
    }

    function testRejectsMalformedInput() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"01";
        vm.expectRevert();
        policy.validate(hex"00", inputs);
    }

    function testRejectsPrefundingWrongRecipient() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0x200), address(0xbad), uint160(1));
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0xbad)));
        policy.validate(hex"02", inputs);
    }

    function testRejectsFlags() public {
        bytes[] memory inputs = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandFlagsNotAllowed.selector, 0, bytes1(0x90)));
        policy.validate(hex"90", inputs);
    }

    function testRejectsEmptyAndMismatchedRoutes() public {
        vm.expectRevert(ICartRoutePolicy.EmptyRoute.selector);
        policy.validate(hex"", new bytes[](0));
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandInputLengthMismatch.selector, 1, 0));
        policy.validate(hex"10", new bytes[](0));
    }
}
