// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";

import {CartRoutePolicy} from "../../cart/CartRoutePolicy.sol";
import {ICartRoutePolicy} from "../../cart/ICartRoutePolicy.sol";

contract CartRoutePolicyTest is Test {
    CartRoutePolicy internal policy;

    address internal constant INPUT = address(0x1002);
    address internal constant OUTPUT = address(0x1003);

    function setUp() public {
        policy = new CartRoutePolicy();
    }

    function testExactOutputSummaryUsesOutputAndInputMaximum() public {
        bytes[] memory inputs = new bytes[](1);
        // V3 exact-output paths are encoded from output token back to input token.
        bytes memory path = abi.encodePacked(OUTPUT, uint24(3000), INPUT);
        inputs[0] = abi.encode(address(1), 7 ether, 11 ether, path, true);

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"01", inputs, INPUT, _outputs());

        assertFalse(summary.exactInput);
        assertEq(summary.inputAmount, 11 ether);
        assertEq(summary.outputAmount, 7 ether);
    }

    function testExactInputSummaryAccumulatesInputAmount() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](2);
        path[0] = INPUT;
        path[1] = OUTPUT;
        inputs[0] = abi.encode(address(1), 5 ether, 1 ether, path, true);

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"08", inputs, INPUT, _outputs());

        assertTrue(summary.exactInput);
        assertEq(summary.inputAmount, 5 ether);
        assertEq(summary.outputAmount, 0);
    }

    function testSummaryAccumulatesInputAcrossCommands() public {
        bytes[] memory inputs = new bytes[](2);
        address[] memory path = new address[](2);
        path[0] = INPUT;
        path[1] = OUTPUT;
        inputs[0] = abi.encode(address(1), 2 ether, 1 ether, path, true);
        inputs[1] = abi.encode(address(1), 3 ether, 1 ether, path, true);

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"0808", inputs, INPUT, _outputs());

        assertEq(summary.inputAmount, 5 ether);
    }

    function testOrderPlanAcceptsMultipleSignedOutputTokens() public {
        address outputB = address(0x1004);
        bytes[] memory inputs = new bytes[](2);
        address[] memory pathA = new address[](2);
        pathA[0] = INPUT;
        pathA[1] = OUTPUT;
        address[] memory pathB = new address[](2);
        pathB[0] = INPUT;
        pathB[1] = outputB;
        inputs[0] = abi.encode(address(1), 2 ether, 1 ether, pathA, true);
        inputs[1] = abi.encode(address(1), 3 ether, 1 ether, pathB, true);
        address[] memory expectedOutputs = new address[](2);
        expectedOutputs[0] = OUTPUT;
        expectedOutputs[1] = outputB;

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"0808", inputs, INPUT, expectedOutputs);

        assertTrue(summary.exactInput);
        assertEq(summary.inputAmount, 5 ether);
    }

    function testOrderPlanRejectsOutputOutsideSignedBasket() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](2);
        path[0] = INPUT;
        path[1] = address(0x9999);
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);
        address[] memory expectedOutputs = new address[](1);
        expectedOutputs[0] = OUTPUT;

        vm.expectRevert(
            abi.encodeWithSelector(ICartRoutePolicy.RouteEndpointMismatch.selector, 0, address(0x9999), OUTPUT)
        );
        policy.validate(hex"08", inputs, INPUT, expectedOutputs);
    }

    function testV4ExactInputSingleSummary() public {
        CartRoutePolicy.PoolKey memory poolKey = CartRoutePolicy.PoolKey({
            currency0: INPUT, currency1: OUTPUT, fee: 3000, tickSpacing: 60, hooks: address(0)
        });
        CartRoutePolicy.ExactInputSingleParams memory swap = CartRoutePolicy.ExactInputSingleParams({
            poolKey: poolKey, zeroForOne: true, amountIn: 5 ether, amountOutMinimum: 4 ether, hookData: bytes("")
        });
        bytes[] memory actions = new bytes[](3);
        actions[0] = abi.encode(swap);
        actions[1] = abi.encode(OUTPUT, 4 ether);
        actions[2] = abi.encode(INPUT, 5 ether);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060f0c", actions);

        ICartRoutePolicy.Summary memory summary = policy.validate(hex"10", inputs, INPUT, _outputs());

        assertTrue(summary.exactInput);
        assertEq(summary.inputAmount, 5 ether);
        assertEq(summary.outputAmount, 0);
    }

    function testV4RejectsRecipientBearingTakeAction() public {
        CartRoutePolicy.PoolKey memory poolKey = CartRoutePolicy.PoolKey({
            currency0: INPUT, currency1: OUTPUT, fee: 3000, tickSpacing: 60, hooks: address(0)
        });
        CartRoutePolicy.ExactInputSingleParams memory swap = CartRoutePolicy.ExactInputSingleParams({
            poolKey: poolKey, zeroForOne: true, amountIn: 5 ether, amountOutMinimum: 4 ether, hookData: bytes("")
        });
        bytes[] memory actions = new bytes[](3);
        actions[0] = abi.encode(swap);
        actions[1] = abi.encode(OUTPUT, address(0x9999), 4 ether);
        actions[2] = abi.encode(INPUT, 5 ether);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060e0c", actions);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandNotAllowed.selector, 0, bytes1(0x0e)));
        policy.validate(hex"10", inputs, INPUT, _outputs());
    }

    function testRejectsRouterCommandFlags() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](2);
        path[0] = INPUT;
        path[1] = OUTPUT;
        inputs[0] = abi.encode(address(1), 1 ether, 1 ether, path, true);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.CommandFlagsNotAllowed.selector, 0, bytes1(0x89)));
        policy.validate(hex"89", inputs, INPUT, _outputs());
    }

    function testRejectsRecipientOtherThanCartSentinel() public {
        bytes[] memory inputs = new bytes[](1);
        address[] memory path = new address[](2);
        path[0] = INPUT;
        path[1] = OUTPUT;
        inputs[0] = abi.encode(address(0x9999), 1 ether, 1 ether, path, true);

        vm.expectRevert(abi.encodeWithSelector(ICartRoutePolicy.InvalidRouteRecipient.selector, 0, address(0x9999)));
        policy.validate(hex"08", inputs, INPUT, _outputs());
    }

    function _outputs() internal pure returns (address[] memory outputs) {
        outputs = new address[](1);
        outputs[0] = OUTPUT;
    }
}
