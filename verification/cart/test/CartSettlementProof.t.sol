// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartProofBase} from "./CartProofBase.sol";
import {ICart} from "cart-src/ICart.sol";

/// @notice Fixed-shape settlement specifications over symbolic uint96 amounts.
/// @dev No listing or fulfillment actions; signatures assumed by ERC1271 model. The uint96 domain
/// avoids unrelated uint256 sum overflows. Baselines vary independently. No arbitrary callbacks.
contract CartSettlementProof is CartProofBase {
    function testNativeGroupedPayout(
        uint96 first,
        uint96 second,
        uint96 spread,
        uint96 ethBaseline,
        uint96 wethBaseline
    ) public {
        vm.assume(first > 0 && second > 0);
        uint256 obligation = uint256(first) + second;
        uint256 quote = obligation + spread;
        _baselines(ethBaseline, wethBaseline);
        vm.deal(address(this), quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _line(address(0), first);
        lines[1] = _line(address(0), second);
        ICart.PayoutRoute memory route;
        assert(_execute(address(0), quote, lines, route));
        assert(PAYEE.balance == obligation);
        assert(address(this).balance == spread);
        _assertBaselines(ethBaseline, wethBaseline);
        assert(cart.executedOrderIds(bytes32(uint256(1))));
    }

    function testNativeToWeth(uint96 amount, uint96 spread, uint96 ethBaseline, uint96 wethBaseline) public {
        vm.assume(amount > 0);
        uint256 quote = uint256(amount) + spread;
        _baselines(ethBaseline, wethBaseline);
        vm.deal(address(this), quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(address(weth), amount);
        ICart.PayoutRoute memory route;
        assert(_execute(address(0), quote, lines, route));
        assert(weth.balanceOf(PAYEE) == amount);
        assert(PAYEE.balance == 0);
        assert(address(this).balance == spread);
        assert(weth.balanceOf(address(this)) == 0);
        _assertBaselines(ethBaseline, wethBaseline);
    }

    function testWethToNative(uint96 amount, uint96 spread, uint96 ethBaseline, uint96 wethBaseline) public {
        vm.assume(amount > 0);
        uint256 quote = uint256(amount) + spread;
        _baselines(ethBaseline, wethBaseline);
        weth.mint(address(this), quote);
        // Back both the preserved WETH baseline and newly supplied payment tokens.
        vm.deal(address(weth), uint256(wethBaseline) + quote);
        vm.deal(address(this), 0);
        weth.approve(address(cart), quote);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(address(0), amount);
        ICart.PayoutRoute memory route;
        assert(_execute(address(weth), quote, lines, route));
        assert(PAYEE.balance == amount);
        assert(weth.balanceOf(PAYEE) == 0);
        assert(weth.balanceOf(address(this)) == spread);
        assert(address(this).balance == 0);
        assert(address(weth).balance == uint256(wethBaseline) + spread);
        _assertBaselines(ethBaseline, wethBaseline);
    }

    function testErc20TemporaryApprovals(uint96 amount, uint96 spread, uint96 quote, uint96 baseline) public {
        vm.assume(amount > 0 && quote > 0);
        payment.mint(address(this), quote);
        payment.mint(address(cart), baseline);
        output.mint(address(cart), baseline);
        output.mint(address(router), uint256(amount) + spread);
        payment.approve(address(cart), quote);
        router.configure(permit2, payment, output, quote, uint256(amount) + spread);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _line(address(output), amount);
        address[] memory path = new address[](2);
        path[0] = address(payment);
        path[1] = address(output);
        ICart.PayoutRoute memory route;
        route.commands = hex"09";
        route.inputs = new bytes[](1);
        route.inputs[0] = abi.encode(address(1), uint256(amount) + spread, uint256(quote), path, true);
        assert(_execute(address(payment), quote, lines, route));
        assert(payment.balanceOf(address(cart)) == baseline);
        assert(output.balanceOf(address(cart)) == baseline);
        assert(output.balanceOf(PAYEE) == amount);
        assert(output.balanceOf(address(this)) == spread);
        assert(payment.balanceOf(router.SINK()) == quote);
        assert(router.observedCartAllowance() == quote);
        assert(router.observedPermit2Allowance() == quote);
        assert(payment.allowance(address(cart), address(permit2)) == 0);
        (uint160 approved,,) = permit2.allowance(address(cart), address(payment), address(router));
        assert(approved == 0);
    }

    function testConcreteNativeWitness() public {
        testNativeGroupedPayout(11, 7, 3, 5, 13);
    }

    function testConcreteWrapWitness() public {
        testNativeToWeth(11, 3, 5, 13);
    }

    function testConcreteUnwrapWitness() public {
        testWethToNative(11, 3, 5, 13);
    }

    function testConcreteApprovalWitness() public {
        testErc20TemporaryApprovals(11, 3, 17, 5);
    }

    function _baselines(uint96 ethBaseline, uint96 wethBaseline) private {
        vm.deal(address(cart), ethBaseline);
        weth.mint(address(cart), wethBaseline);
        vm.deal(address(weth), wethBaseline);
        vm.deal(PAYEE, 0);
    }

    function _assertBaselines(uint96 ethBaseline, uint96 wethBaseline) private view {
        assert(address(cart).balance == ethBaseline);
        assert(weth.balanceOf(address(cart)) == wethBaseline);
    }
}
