// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartProofBase} from "./CartProofBase.sol";
import {ICart} from "cart-src/ICart.sol";

/// @notice Approval revocation must clear authority that routing did not consume.
/// @dev The exact-transfer dependency models spend quote minus one, leaving one unit of both
/// allowance layers for Cart to revoke explicitly. Signatures are assumed; routing uses the
/// fixed exact-output model. This executes the real Cart proxy and payment delegatecalls.
contract CartApprovalProof is CartProofBase {
    function testUnusedApprovalRevoked(
        uint96 amount,
        uint96 spread,
        uint96 spend,
        uint96 inputBaseline,
        uint96 outputBaseline
    ) public {
        vm.assume(amount > 0 && spend > 0);
        uint256 quote = uint256(spend) + 1;
        uint256 received = uint256(amount) + spread;
        payment.mint(address(this), quote);
        payment.mint(address(cart), inputBaseline);
        output.mint(address(cart), outputBaseline);
        output.mint(address(router), received);
        payment.approve(address(cart), quote);
        router.configure(permit2, payment, output, spend, received);

        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(address(output), amount);
        address[] memory path = new address[](2);
        path[0] = address(payment);
        path[1] = address(output);
        ICart.PayoutRoute memory route;
        route.commands = hex"09";
        route.inputs = new bytes[](1);
        route.inputs[0] = abi.encode(address(1), received, uint256(spend), path, true);

        assert(_execute(address(payment), quote, lines, route));
        assert(payment.balanceOf(address(cart)) == inputBaseline);
        assert(output.balanceOf(address(cart)) == outputBaseline);
        assert(output.balanceOf(PAYEE) == amount);
        assert(output.balanceOf(address(this)) == spread);
        assert(payment.balanceOf(router.SINK()) == spend);
        assert(payment.balanceOf(address(this)) == 1);
        assert(router.observedCartAllowance() == quote);
        assert(router.observedPermit2Allowance() == quote);
        assert(payment.allowance(address(cart), address(permit2)) == 0);
        (uint160 approved, uint48 expiration,) = permit2.allowance(address(cart), address(payment), address(router));
        assert(approved == 0);
        assert(expiration == 0);
    }

    function testConcreteUnusedApprovalWitness() public {
        testUnusedApprovalRevoked(11, 3, 17, 5, 7);
    }
}
