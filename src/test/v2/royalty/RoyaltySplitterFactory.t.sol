// SPDX-License-Identifier: MIT
pragma solidity =0.8.18;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PaymentSplitter} from "@openzeppelin/contracts/finance/PaymentSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoyaltySplitterFactory} from "../../../v2/royalty/RoyaltySplitterFactory.sol";
import {TestToken} from "../utils/TestToken.sol";

contract RejectingRoyaltyPayee {
    receive() external payable {
        revert("ETH rejected");
    }
}

contract RoyaltySplitterFactoryTest is Test {
    RoyaltySplitterFactory private factory;
    TestToken private token;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant CALLER = address(0xCA11E2);

    function setUp() public {
        factory = new RoyaltySplitterFactory();
        token = new TestToken();
        vm.deal(address(this), 100 ether);
        vm.deal(ALICE, 0);
        vm.deal(BOB, 0);
        vm.deal(CAROL, 0);
        vm.deal(CALLER, 0);
    }

    function test_PredictedAddressAcceptsFundsBeforeDeployment() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        bytes32 configHash = keccak256(abi.encode(recipients, shares));
        bytes32 initCodeHash =
            keccak256(bytes.concat(type(PaymentSplitter).creationCode, abi.encode(recipients, shares)));
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), configHash, initCodeHash))))
        );
        address predicted = factory.predictSplitter(recipients, shares);
        assertEq(predicted, expected);
        assertEq(predicted.code.length, 0);
        assertEq(factory.configurationHash(predicted), bytes32(0));

        _sendEth(predicted, 4 ether);
        token.mint(predicted, 400);
        PaymentSplitter splitter = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertEq(address(splitter), predicted);
        assertEq(factory.configurationHash(predicted), configHash);
        splitter.release(payable(ALICE));
        splitter.release(payable(BOB));
        splitter.release(IERC20(address(token)), ALICE);
        splitter.release(IERC20(address(token)), BOB);
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, 3 ether);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 300);
        assertEq(predicted.balance, 0);
        assertEq(token.balanceOf(predicted), 0);
    }

    function test_AnyCallerReusesFundedSplitterWithoutReinitializingOrEmittingAgain() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        vm.recordLogs();
        vm.prank(ALICE);
        address first = factory.getOrCreateSplitter(recipients, shares);
        _sendEth(first, 4 ether);
        vm.prank(BOB);
        address second = factory.getOrCreateSplitter(recipients, shares);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        uint256 factoryEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(factory)) {
                factoryEvents++;
                assertEq(logs[i].topics[0], keccak256("RoyaltySplitterCreated(address,bytes32)"));
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(first))));
                assertEq(logs[i].topics[2], keccak256(abi.encode(recipients, shares)));
            }
        }
        assertEq(factoryEvents, 1);
        assertEq(first, second);
        PaymentSplitter splitter = PaymentSplitter(payable(second));
        vm.prank(CALLER);
        splitter.release(payable(ALICE));
        vm.prank(CALLER);
        splitter.release(payable(BOB));
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, 3 ether);
        assertEq(CALLER.balance, 0);
        assertEq(second.balance, 0);
    }

    function test_SharedRecipientHasIndependentSplitsForDifferentShares() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        PaymentSplitter first = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        shares[1] = 1;
        address predictedSecond = factory.predictSplitter(recipients, shares);
        assertEq(predictedSecond.code.length, 0);
        PaymentSplitter second = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertTrue(address(first) != address(second));
        assertEq(address(second), predictedSecond);
        _sendEth(address(first), 4 ether);
        _sendEth(address(second), 4 ether);

        first.release(payable(ALICE));
        second.release(payable(ALICE));
        first.release(payable(BOB));
        second.release(payable(BOB));
        assertEq(ALICE.balance, 3 ether);
        assertEq(BOB.balance, 5 ether);
        assertEq(first.released(ALICE), 1 ether);
        assertEq(second.released(ALICE), 2 ether);
        shares[1] = 3;
        assertEq(factory.getOrCreateSplitter(recipients, shares), address(first));
    }

    function test_RecipientOrderIsPartOfIdentityEvenWithEquivalentPayouts() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        PaymentSplitter first = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        recipients[0] = BOB;
        recipients[1] = ALICE;
        shares[0] = 3;
        shares[1] = 1;
        PaymentSplitter second = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertTrue(address(first) != address(second));
        _sendEth(address(first), 4 ether);
        _sendEth(address(second), 4 ether);
        first.release(payable(ALICE));
        second.release(payable(ALICE));
        assertEq(ALICE.balance, 2 ether);
        assertEq(first.releasable(BOB), 3 ether);
        assertEq(second.releasable(BOB), 3 ether);
    }

    function test_ChangedRecipientDoesNotChangeExistingSplitterEntitlements() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        PaymentSplitter first = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        recipients[0] = CAROL;
        PaymentSplitter second = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertTrue(address(first) != address(second));
        _sendEth(address(first), 4 ether);
        _sendEth(address(second), 4 ether);
        first.release(payable(ALICE));
        second.release(payable(CAROL));
        vm.expectRevert("PaymentSplitter: account has no shares");
        second.release(payable(ALICE));
        assertEq(ALICE.balance, 1 ether);
        assertEq(CAROL.balance, 1 ether);
        assertEq(first.releasable(BOB), 3 ether);
        assertEq(second.releasable(BOB), 3 ether);
    }

    function test_ScaledSharesAreDistinctExactTermsRatherThanNormalized() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        PaymentSplitter first = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        shares[0] = 2;
        shares[1] = 6;
        PaymentSplitter second = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertTrue(address(first) != address(second));
        _sendEth(address(first), 4 ether);
        _sendEth(address(second), 4 ether);
        first.release(payable(ALICE));
        second.release(payable(ALICE));
        assertEq(ALICE.balance, 2 ether);
        assertEq(first.releasable(BOB), 3 ether);
        assertEq(second.releasable(BOB), 3 ether);
    }

    function test_EthReleaseTracksCumulativeReceiptsAndCannotPayTwice() public {
        PaymentSplitter splitter = _create();
        _sendEth(address(splitter), 4 ether);
        vm.prank(CALLER);
        splitter.release(payable(ALICE));
        assertEq(ALICE.balance, 1 ether);
        vm.expectRevert("PaymentSplitter: account is not due payment");
        splitter.release(payable(ALICE));
        vm.expectRevert("PaymentSplitter: account has no shares");
        splitter.release(payable(CALLER));
        _sendEth(address(splitter), 4 ether);
        vm.prank(CALLER);
        splitter.release(payable(ALICE));
        vm.prank(CALLER);
        splitter.release(payable(BOB));
        assertEq(ALICE.balance, 2 ether);
        assertEq(BOB.balance, 6 ether);
        assertEq(CALLER.balance, 0);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.totalReleased(), 8 ether);
        assertEq(splitter.released(ALICE), 2 ether);
        assertEq(splitter.releasable(ALICE), 0);
        assertEq(splitter.releasable(BOB), 0);
    }

    function test_Erc20ReleasePaysPayeesNotCallerAndTracksCumulativeReceipts() public {
        PaymentSplitter splitter = _create();
        IERC20 asset = IERC20(address(token));
        _sendEth(address(splitter), 4 ether);
        token.mint(address(splitter), 400);
        vm.prank(CALLER);
        splitter.release(asset, ALICE);
        assertEq(token.balanceOf(ALICE), 100);
        vm.expectRevert("PaymentSplitter: account is not due payment");
        splitter.release(asset, ALICE);
        vm.expectRevert("PaymentSplitter: account has no shares");
        splitter.release(asset, CALLER);
        token.mint(address(splitter), 200);
        vm.prank(CALLER);
        splitter.release(asset, ALICE);
        vm.prank(CALLER);
        splitter.release(asset, BOB);
        assertEq(token.balanceOf(ALICE), 150);
        assertEq(token.balanceOf(BOB), 450);
        assertEq(token.balanceOf(CALLER), 0);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(splitter.totalReleased(asset), 600);
        assertEq(splitter.released(asset, ALICE), 150);
        assertEq(splitter.releasable(asset, ALICE), 0);
        assertEq(splitter.releasable(asset, BOB), 0);
        assertEq(address(splitter).balance, 4 ether);
        assertEq(splitter.releasable(ALICE), 1 ether);
        assertEq(splitter.totalReleased(), 0);
    }

    function test_RejectingEthPayeeCannotBlockOthersOrErc20Releases() public {
        RejectingRoyaltyPayee rejectingPayee = new RejectingRoyaltyPayee();
        (address[] memory recipients, uint256[] memory shares) = _terms();
        recipients[1] = address(rejectingPayee);
        PaymentSplitter splitter = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        _sendEth(address(splitter), 4 ether);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        splitter.release(payable(address(rejectingPayee)));
        assertEq(splitter.released(address(rejectingPayee)), 0);
        assertEq(splitter.totalReleased(), 0);
        assertEq(splitter.releasable(address(rejectingPayee)), 3 ether);
        splitter.release(payable(ALICE));
        assertEq(ALICE.balance, 1 ether);
        assertEq(address(splitter).balance, 3 ether);
        assertEq(splitter.releasable(address(rejectingPayee)), 3 ether);

        token.mint(address(splitter), 400);
        splitter.release(IERC20(address(token)), address(rejectingPayee));
        splitter.release(IERC20(address(token)), ALICE);
        assertEq(token.balanceOf(address(rejectingPayee)), 300);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(address(splitter).balance, 3 ether);
    }

    function test_EthRoundingDustBecomesPayableWithLaterReceipts() public {
        PaymentSplitter splitter = _create();
        _sendEth(address(splitter), 1);
        vm.expectRevert("PaymentSplitter: account is not due payment");
        splitter.release(payable(ALICE));
        vm.expectRevert("PaymentSplitter: account is not due payment");
        splitter.release(payable(BOB));
        assertEq(address(splitter).balance, 1);
        _sendEth(address(splitter), 3);
        splitter.release(payable(ALICE));
        splitter.release(payable(BOB));
        assertEq(ALICE.balance, 1);
        assertEq(BOB.balance, 3);
        assertEq(address(splitter).balance, 0);
    }

    function test_Erc20RoundingPreservesDustAndCumulativeEntitlements() public {
        PaymentSplitter splitter = _create();
        IERC20 asset = IERC20(address(token));
        token.mint(address(splitter), 5);
        splitter.release(asset, ALICE);
        splitter.release(asset, BOB);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(BOB), 3);
        assertEq(token.balanceOf(address(splitter)), 1);
        vm.expectRevert("PaymentSplitter: account is not due payment");
        splitter.release(asset, ALICE);
        token.mint(address(splitter), 3);
        splitter.release(asset, ALICE);
        splitter.release(asset, BOB);
        assertEq(token.balanceOf(ALICE), 2);
        assertEq(token.balanceOf(BOB), 6);
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(splitter.totalReleased(asset), 8);
    }

    function test_ExternallyDeployedSplitterIsNotFactoryProvenance() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        PaymentSplitter externalSplitter = new PaymentSplitter(recipients, shares);
        assertEq(factory.configurationHash(address(externalSplitter)), bytes32(0));
        PaymentSplitter created = PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
        assertTrue(address(externalSplitter) != address(created));
        assertEq(factory.configurationHash(address(created)), keccak256(abi.encode(recipients, shares)));
        _sendEth(address(externalSplitter), 4 ether);
        _sendEth(address(created), 4 ether);
        externalSplitter.release(payable(ALICE));
        created.release(payable(ALICE));
        assertEq(ALICE.balance, 2 ether);
    }

    function test_EmptyRecipientsRevertWithoutPartialDeployment() public {
        _assertInvalidConfiguration(new address[](0), new uint256[](0));
    }

    function test_MismatchedLengthsRevertWithoutPartialDeployment() public {
        (address[] memory recipients,) = _terms();
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1;
        _assertInvalidConfiguration(recipients, shares);
    }

    function test_EmptySharesRevertWithoutPartialDeployment() public {
        (address[] memory recipients,) = _terms();
        _assertInvalidConfiguration(recipients, new uint256[](0));
    }

    function test_ZeroRecipientRevertsWithoutPartialDeployment() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        recipients[1] = address(0);
        _assertInvalidConfiguration(recipients, shares);
    }

    function test_DuplicateRecipientRevertsWithoutPartialDeployment() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        recipients[1] = ALICE;
        _assertInvalidConfiguration(recipients, shares);
    }

    function test_ZeroSharesRevertWithoutPartialDeployment() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        shares[1] = 0;
        _assertInvalidConfiguration(recipients, shares);
    }

    function test_OverflowingTotalSharesRevertsWithoutPartialDeployment() public {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        shares[0] = type(uint256).max;
        shares[1] = 1;
        _assertInvalidConfiguration(recipients, shares);
    }

    function _assertInvalidConfiguration(address[] memory recipients, uint256[] memory shares) private {
        address predicted = factory.predictSplitter(recipients, shares);
        vm.expectRevert("Create2: Failed on deploy");
        factory.getOrCreateSplitter(recipients, shares);
        assertEq(predicted.code.length, 0);
        assertEq(factory.configurationHash(predicted), bytes32(0));
        vm.expectRevert("Create2: Failed on deploy");
        factory.getOrCreateSplitter(recipients, shares);
        assertEq(predicted.code.length, 0);
        assertEq(factory.configurationHash(predicted), bytes32(0));

        PaymentSplitter valid = _create();
        _sendEth(address(valid), 4 ether);
        valid.release(payable(ALICE));
        valid.release(payable(BOB));
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, 3 ether);
        assertEq(address(valid).balance, 0);
    }

    function _create() private returns (PaymentSplitter) {
        (address[] memory recipients, uint256[] memory shares) = _terms();
        return PaymentSplitter(payable(factory.getOrCreateSplitter(recipients, shares)));
    }

    function _terms() private pure returns (address[] memory recipients, uint256[] memory shares) {
        recipients = new address[](2);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        shares = new uint256[](2);
        shares[0] = 1;
        shares[1] = 3;
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        assertTrue(success);
    }
}
