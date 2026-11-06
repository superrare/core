// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";
import {CartRoutePolicyFixture} from "./CartRoutePolicyFixture.sol";

/// @notice Verification-oriented boundary tests for the opaque route policy.
contract CartRoutePolicyVerificationTest is CartRoutePolicyFixture {
    function testGuardRejectsMalformedV3Path() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0x9999), type(uint256).max, hex"01", address(0x7777), false);

        vm.expectRevert();
        policy.validate(hex"00", inputs);
    }

    function testGuardRejectsMalformedV4Actions() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"ffffffffffffffff", address(0x9999), type(uint256).max);

        vm.expectRevert();
        policy.validate(hex"10", inputs);
    }

    function testGuardRejectsWrongRecipient() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(0x9999), type(uint256).max, address(0x8888));

        vm.expectRevert();
        policy.validate(hex"04", inputs);
    }

    function testMalformedInputRejectedBeforeRouter() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = hex"00";

        // The policy accepts the command family; a real Universal Router call owns the next
        // validation boundary and is expected to reject malformed command input.
        vm.expectRevert();
        policy.validate(hex"09", inputs);
    }

    function testRejectsAllowRevertFlagEvenForSupportedCommand() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandFlagsNotAllowed.selector, 0, bytes1(0x89)));
        policy.validate(hex"89", inputs);
    }

    function testRejectsPositionAndPoolInitializationCommands() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x03)));
        policy.validate(hex"03", inputs);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x13)));
        policy.validate(hex"13", inputs);
    }

    function testRejectsSubPlanCommand() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x21)));
        policy.validate(hex"21", inputs);
    }
}
