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
        params[1] = abi.encode(address(0x100), 100);
        params[2] = abi.encode(address(0x200), address(0xbad), 50);
        inputs[0] = abi.encode(hex"080c0e", params);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0xbad)));
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

    function testAcceptsProviderV4SettleAndTake() public {
        bytes[] memory inputs = new bytes[](1);
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(0x100), 0, true);
        params[2] = abi.encode(address(0x200), address(this), 50);
        inputs[0] = abi.encode(hex"090b0e", params);
        address[] memory assets = policy.validate(hex"10", inputs);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(0x100));
        assertEq(assets[1], address(0x200));
    }

    function testAcceptsV3RouterCustodyThenUnwrapToCart() public {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(2), 50, 100, abi.encodePacked(address(0x200), uint24(3000), address(0x100)), true);
        inputs[1] = abi.encode(address(this), 50);
        address[] memory assets = policy.validate(hex"010c", inputs);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(0x200));
        assertEq(assets[1], address(0x100));
    }

    function testSupportsOnlyTheTwoSettlementAndTakeForms() public {
        bytes[] memory inputs = new bytes[](1);
        for (uint8 swap = 6; swap <= 9; ++swap) {
            for (uint8 settle = 11; settle <= 12; ++settle) {
                for (uint8 take = 14; take <= 15; ++take) {
                    bytes[] memory params = new bytes[](3);
                    params[1] = settle == 11 ? abi.encode(address(0x100), 0, false) : abi.encode(address(0x100), 100);
                    params[2] = take == 14 ? abi.encode(address(0x200), address(1), 0) : abi.encode(address(0x200), 50);
                    inputs[0] = abi.encode(abi.encodePacked(swap, settle, take), params);
                    address[] memory assets = policy.validate(hex"10", inputs);
                    assertEq(assets.length, 2);
                    assertEq(assets[0], address(0x100));
                    assertEq(assets[1], address(0x200));
                }
            }
        }
    }

    function testRejectsV4TakeToRouterAndUnsupportedActions() public {
        bytes[] memory inputs = new bytes[](1);
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(0x100), 100);
        params[2] = abi.encode(address(0x200), address(2), 50);
        inputs[0] = abi.encode(hex"080c0e", params);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(2)));
        policy.validate(hex"10", inputs);
        inputs[0] = abi.encode(hex"080d0f", params);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteInput.selector, 0));
        policy.validate(hex"10", inputs);
        inputs[0] = abi.encode(hex"080c10", params);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteInput.selector, 0));
        policy.validate(hex"10", inputs);
    }

    function testExecutionContextCannotBeSpoofedByPreview() public {
        address target = address(0xcafe);
        address other = address(0xbeef);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0), target, 0);
        policy.validateFor(target, hex"04", inputs);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, target));
        vm.prank(other);
        policy.validate(hex"04", inputs);
        vm.prank(target);
        policy.validate(hex"04", inputs);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, target));
        policy.validateFor(other, hex"04", inputs);
    }

    function testRejectsZeroRecipientEvenForZeroPreviewTarget() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0)));
        policy.validateFor(address(0), hex"04", inputs);
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
