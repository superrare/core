// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";

import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";

/// @notice Tests for Cart's shallow Universal Router command-family boundary.
/// @dev Inputs are intentionally opaque here. Universal Router owns their decoding and semantics.
contract CartRoutePolicyTest is Test {
    CartRoutePolicy internal policy;

    function setUp() public {
        policy = new CartRoutePolicy();
    }

    function testAcceptsEverySupportedCommandWithOpaqueInputs() public {
        bytes memory commands = hex"0001020408090b0c10";
        bytes[] memory inputs = new bytes[](commands.length);
        for (uint256 i = 0; i < inputs.length; ++i) {
            inputs[i] = abi.encodePacked(bytes32(uint256(i + 1)), hex"deadbeef");
        }

        policy.validate(commands, inputs);
    }

    function testAcceptsMalformedOpaqueV3Input() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"01";

        policy.validate(hex"00", inputs);
    }

    function testAcceptsMalformedOpaqueV4Input() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(bytes4(0xdeadbeef), hex"00");

        policy.validate(hex"10", inputs);
    }

    function testAcceptsOpaqueRecipientAndPayerFields() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0x9999), false, address(0x8888), uint256(7));

        policy.validate(hex"08", inputs);
    }

    function testRejectsEmptyRoute() public {
        vm.expectRevert(ICartRoutePolicy.EmptyRoute.selector);
        policy.validate(bytes(""), new bytes[](0));
    }

    function testRejectsCommandInputLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandInputLengthMismatch.selector, 1, 0));
        policy.validate(hex"08", new bytes[](0));
    }

    function testRejectsTooManyCommands() public {
        bytes memory commands = new bytes(33);
        bytes[] memory inputs = new bytes[](commands.length);
        for (uint256 i = 0; i < inputs.length; ++i) {
            inputs[i] = bytes("");
        }

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.RouteTooManyCommands.selector, commands.length));
        policy.validate(commands, inputs);
    }

    function testRejectsTooManyInputs() public {
        bytes[] memory inputs = new bytes[](33);
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.RouteTooManyInputs.selector, 33));
        policy.validate(hex"08", inputs);
    }

    function testRejectsUnsupportedCommand() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x03)));
        policy.validate(hex"03", inputs);
    }

    function testRejectsCommandFlags() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandFlagsNotAllowed.selector, 0, bytes1(0x80)));
        policy.validate(hex"80", inputs);
    }
}
