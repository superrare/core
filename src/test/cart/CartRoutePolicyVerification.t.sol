// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";
import {CartRoutePolicyTest} from "./CartRoutePolicy.t.sol";

/// @notice Default-deny coverage for malformed and unsupported Universal Router plans.
contract CartRoutePolicyVerificationTest is CartRoutePolicyTest {
    function testRejectsCommandInputLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandInputLengthMismatch.selector, 1, 0));
        policy.validate(hex"08", new bytes[](0), INPUT, _outputs());
    }

    function testRejectsUnsupportedCommand() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes("");

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x04)));
        policy.validate(hex"04", inputs, INPUT, _outputs());
    }

    function testRejectsPermit2RouterPayerMode() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = _v2Path(INPUT, OUTPUT);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, false);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidPayer.selector, 0));
        policy.validate(hex"08", inputs, INPUT, _outputs());
    }

    function testRejectsMixedExactInputAndExactOutputCommands() public {
        bytes[] memory inputs = new bytes[](2);
        address[] memory path = _v2Path(INPUT, OUTPUT);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        inputs[1] = abi.encode(address(1), 1 ether, 1 ether, path, true);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteMode.selector, 1));
        policy.validate(hex"0809", inputs, INPUT, _outputs());
    }

    function testRejectsUnexpectedInputEndpoint() public {
        address wrongInput = address(0x2001);
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = _v2Path(wrongInput, OUTPUT);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.RouteEndpointMismatch.selector, 0, wrongInput, INPUT));
        policy.validate(hex"08", inputs, INPUT, _outputs());
    }

    function testAcceptsUnapprovedIntermediateToken() public {
        address intermediate = address(0x2002);
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](3);
        path[0] = INPUT;
        path[1] = intermediate;
        path[2] = OUTPUT;
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"08", inputs, INPUT, _outputs());
        assertEq(summary.inputAmount, 1 ether);
    }

    function testRejectsMalformedV3Path() public {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, abi.encodePacked(INPUT), true);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidPath.selector, 0));
        policy.validate(hex"00", inputs, INPUT, _outputs());
    }

    function _v2Path(address input, address output) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = input;
        path[1] = output;
    }
}
