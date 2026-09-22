// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "src/memberships/CreatorMemberships.sol";

contract MembershipTestToken is ERC20 {
  constructor() ERC20("Test USDC", "USDC") {}
  function decimals() public pure override returns (uint8) {
    return 6;
  }
  function mint(address recipient, uint256 amount) external {
    _mint(recipient, amount);
  }
}

contract CreatorMembershipsTest is Test {
  MembershipTestToken internal token;
  CreatorMemberships internal memberships;
  uint256 internal operatorKey = 0xa11ce;
  address internal payer = address(0x100);
  address internal creator = address(0x200);
  address internal treasury = address(0x300);
  bytes32 internal subscriptionId = keccak256("enrollment");
  uint256 internal amount = 10e6;

  function setUp() public {
    vm.warp(DateTimeLib.dateToTimestamp(2026, 1, 31) + 12 hours);
    token = new MembershipTestToken();
    memberships = new CreatorMemberships(address(token), treasury, vm.addr(operatorKey), address(this));
    token.mint(payer, 1000e6);
    vm.prank(payer);
    token.approve(address(memberships), 120e6);
  }

  function terms() internal view returns (CreatorMemberships.MembershipTerms memory) {
    return CreatorMemberships.MembershipTerms(subscriptionId, payer, creator, amount, block.timestamp + 10 minutes);
  }

  function sign(CreatorMemberships.MembershipTerms memory value) internal view returns (bytes memory) {
    bytes32 domain = keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("SuperRare Creator Memberships"),
        keccak256("1"),
        block.chainid,
        address(memberships)
      )
    );
    bytes32 digest = keccak256(
      abi.encodePacked(
        "\x19\x01",
        domain,
        keccak256(
          abi.encode(
            memberships.TERMS_TYPEHASH(),
            value.subscriptionId,
            value.payer,
            value.creator,
            value.amount,
            value.validUntil
          )
        )
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function subscribe() internal returns (uint256 end) {
    CreatorMemberships.MembershipTerms memory value = terms();
    bytes memory signature = sign(value);
    vm.prank(payer);
    memberships.subscribe(value, signature);
    (, , , end, ) = memberships.subscriptions(subscriptionId);
  }

  function testFirstPaymentSplitsExactlyAndUsesCalendarMonth() public {
    uint256 end = subscribe();
    assertEq(token.balanceOf(creator), 9_500_000);
    assertEq(token.balanceOf(treasury), 500_000);
    assertEq(token.balanceOf(address(memberships)), 0);
    assertEq(end, DateTimeLib.dateToTimestamp(2026, 2, 28) + 12 hours);
  }

  function testFuzzFeeSplit(uint256 cents) public {
    amount = bound(cents, 100, 50_000) * 10_000;
    vm.prank(payer);
    token.approve(address(memberships), amount);
    subscribe();
    assertEq(token.balanceOf(creator), (amount * 95) / 100);
    assertEq(token.balanceOf(treasury), (amount * 5) / 100);
  }

  function testLeapYearAndDecemberBoundaries() public {
    vm.warp(DateTimeLib.dateToTimestamp(2028, 1, 31));
    assertEq(subscribe(), DateTimeLib.dateToTimestamp(2028, 2, 29));
    vm.warp(DateTimeLib.dateToTimestamp(2028, 12, 31));
    subscriptionId = keccak256("new-enrollment");
    assertEq(subscribe(), DateTimeLib.dateToTimestamp(2029, 1, 31));
  }

  function testRenewalNeedsNoMemberTransactionAndCannotRepeat() public {
    uint256 end = subscribe();
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(subscriptionId, end);
    vm.warp(end);
    memberships.renew(subscriptionId, end);
    assertEq(token.balanceOf(creator), 19e6);
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(subscriptionId, end);
  }

  function testLateRecoveryBuysFullMonthWithoutArrears() public {
    uint256 end = subscribe();
    vm.warp(end + 2 days);
    memberships.renew(subscriptionId, end);
    (, , , uint256 newEnd, ) = memberships.subscriptions(subscriptionId);
    assertEq(newEnd, DateTimeLib.addMonths(block.timestamp, 1));
    assertEq(token.balanceOf(payer), 980e6);
  }

  function testExpiredRetryWindowRequiresReauthorization() public {
    uint256 end = subscribe();
    vm.warp(end + 7 days + 1);
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(subscriptionId, end);
    bytes32 oldId = subscriptionId;
    subscriptionId = keccak256("new-enrollment");
    subscribe();
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(oldId, end);
  }

  function testCancelWhilePausedPreservesPaidPeriodAndPreventsRenewal() public {
    uint256 end = subscribe();
    memberships.pause();
    vm.prank(payer);
    memberships.cancel(subscriptionId);
    (, , , uint256 paidThrough, bool canceled) = memberships.subscriptions(subscriptionId);
    assertTrue(canceled);
    assertEq(paidThrough, end);
    memberships.unpause();
    vm.warp(end);
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(subscriptionId, end);
  }

  function testRevokedAllowanceDoesNotExtendOrPartiallyPay() public {
    uint256 end = subscribe();
    vm.prank(payer);
    token.approve(address(memberships), amount - 1);
    vm.warp(end);
    vm.expectRevert();
    memberships.renew(subscriptionId, end);
    (, , , uint256 paidThrough, ) = memberships.subscriptions(subscriptionId);
    assertEq(paidThrough, end);
    assertEq(token.balanceOf(creator), 9_500_000);
    assertEq(token.balanceOf(treasury), 500_000);
  }

  function testInsufficientBalanceDoesNotExtend() public {
    uint256 end = subscribe();
    uint256 balance = token.balanceOf(payer);
    vm.prank(payer);
    token.transfer(address(0xbeef), balance);
    vm.warp(end);
    vm.expectRevert();
    memberships.renew(subscriptionId, end);
    (, , , uint256 paidThrough, ) = memberships.subscriptions(subscriptionId);
    assertEq(paidThrough, end);
  }

  function testRejectsWrongPayerAndTamperedPrice() public {
    CreatorMemberships.MembershipTerms memory value = terms();
    bytes memory signature = sign(value);
    vm.expectRevert(CreatorMemberships.InvalidTerms.selector);
    memberships.subscribe(value, signature);
    value.amount += 10_000;
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    memberships.subscribe(value, signature);
  }

  function testRejectsExpiredAndOtherChainAuthorization() public {
    CreatorMemberships.MembershipTerms memory value = terms();
    bytes memory signature = sign(value);
    vm.chainId(block.chainid + 1);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    memberships.subscribe(value, signature);
    vm.warp(value.validUntil + 1);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.InvalidTerms.selector);
    memberships.subscribe(value, signature);
  }

  function testRejectsDuplicateAndOverlappingEnrollment() public {
    subscribe();
    CreatorMemberships.MembershipTerms memory value = terms();
    bytes memory signature = sign(value);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.AlreadySubscribed.selector);
    memberships.subscribe(value, signature);
    value.subscriptionId = keccak256("duplicate-wallet");
    signature = sign(value);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.AlreadySubscribed.selector);
    memberships.subscribe(value, signature);
  }

  function testOnlyMemberOrOperatorCanCancel() public {
    subscribe();
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    memberships.cancel(subscriptionId);
    vm.prank(vm.addr(operatorKey));
    memberships.cancel(subscriptionId);
    (, , , , bool canceled) = memberships.subscriptions(subscriptionId);
    assertTrue(canceled);
  }

  function testEndingArtistStopsAllRenewalsAndNewPayments() public {
    uint256 end = subscribe();
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    memberships.endCreator(creator);
    vm.prank(creator);
    memberships.endCreator(creator);
    vm.warp(end);
    vm.expectRevert(CreatorMemberships.RenewalUnavailable.selector);
    memberships.renew(subscriptionId, end);
    CreatorMemberships.MembershipTerms memory value = terms();
    value.subscriptionId = keccak256("another-enrollment");
    bytes memory signature = sign(value);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.InvalidTerms.selector);
    memberships.subscribe(value, signature);
  }

  function testAuthorizationCannotReplayOnAnotherContract() public {
    CreatorMemberships.MembershipTerms memory value = terms();
    bytes memory signature = sign(value);
    CreatorMemberships another = new CreatorMemberships(address(token), treasury, vm.addr(operatorKey), address(this));
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    another.subscribe(value, signature);
  }

  function testOwnerRotationInvalidatesOldQuotesAndPreservesEnrolledTerms() public {
    uint256 end = subscribe();
    CreatorMemberships.MembershipTerms memory value = terms();
    value.subscriptionId = keccak256("another-member");
    value.payer = address(0x999);
    bytes memory signature = sign(value);
    vm.prank(payer);
    vm.expectRevert("Ownable: caller is not the owner");
    memberships.setOperator(address(0xbeef));
    memberships.setOperator(address(0xbeef));
    vm.prank(value.payer);
    vm.expectRevert(CreatorMemberships.Unauthorized.selector);
    memberships.subscribe(value, signature);
    vm.warp(end);
    memberships.renew(subscriptionId, end);
    assertEq(token.balanceOf(treasury), 1e6);
    assertEq(token.balanceOf(creator), 19e6);
  }

  function testPauseStopsPaymentsButOperatorCanEndArtist() public {
    uint256 end = subscribe();
    memberships.pause();
    vm.warp(end);
    vm.expectRevert("Pausable: paused");
    memberships.renew(subscriptionId, end);
    vm.prank(vm.addr(operatorKey));
    memberships.endCreator(creator);
    assertTrue(memberships.endedCreators(creator));
    (, , , uint256 paidThrough, ) = memberships.subscriptions(subscriptionId);
    assertEq(paidThrough, end);
  }

  function testRejectsInvalidPriceAndSelfMembership() public {
    CreatorMemberships.MembershipTerms memory value = terms();
    value.amount = 500e6 + 10_000;
    bytes memory signature = sign(value);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.InvalidTerms.selector);
    memberships.subscribe(value, signature);
    value.amount = amount;
    value.creator = payer;
    signature = sign(value);
    vm.prank(payer);
    vm.expectRevert(CreatorMemberships.InvalidTerms.selector);
    memberships.subscribe(value, signature);
  }
}
