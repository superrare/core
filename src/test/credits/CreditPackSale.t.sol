// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

import {CreditPackSale} from "../../credits/CreditPackSale.sol";

contract TestUsdc is ERC20 {
  constructor() ERC20("USD Coin", "USDC") {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

contract CreditPackSaleTest is Test {
  event PackPurchased(
    uint256 indexed groupId,
    address indexed recipient,
    bytes32 indexed quoteId,
    address payer,
    uint256 quantity,
    uint256 credits,
    uint256 grossAmount,
    uint256 feeAmount,
    address treasury
  );

  uint16 private constant DEFAULT_FEE_BPS = 500;
  uint256 private constant PACK_PRICE = 4_000_000;
  uint256 private constant PACK_CREDITS = 10;
  bytes32 private constant QUOTE_ID = keccak256("quote-1");

  address private owner = makeAddr("owner");
  address private feeRecipient = makeAddr("feeRecipient");
  address private operator = makeAddr("operator");
  address private treasury = makeAddr("treasury");
  address private coinflow = makeAddr("coinflow");
  address private player = makeAddr("player");
  address private stranger = makeAddr("stranger");

  TestUsdc private usdc;
  CreditPackSale private sale;
  uint256 private groupId;

  function setUp() public {
    usdc = new TestUsdc();
    vm.prank(owner);
    sale = new CreditPackSale(address(usdc), feeRecipient, DEFAULT_FEE_BPS);

    vm.prank(operator);
    groupId = sale.createGroup(treasury, PACK_PRICE, PACK_CREDITS);

    usdc.mint(coinflow, 1_000_000_000);
    vm.prank(coinflow);
    usdc.approve(address(sale), type(uint256).max);
  }

  function _purchase(address _payer, uint256 _quantity, bytes32 _quoteId) private {
    vm.prank(_payer);
    sale.purchase(groupId, player, _quantity, PACK_PRICE, PACK_CREDITS, _quoteId);
  }

  function test_constructor_rejectsZeroCurrency() public {
    vm.expectRevert(CreditPackSale.CurrencyCannotBeZeroAddress.selector);
    new CreditPackSale(address(0), feeRecipient, DEFAULT_FEE_BPS);
  }

  function test_constructor_rejectsZeroFeeRecipient() public {
    vm.expectRevert(CreditPackSale.FeeRecipientCannotBeZeroAddress.selector);
    new CreditPackSale(address(usdc), address(0), DEFAULT_FEE_BPS);
  }

  function test_constructor_rejectsFeeAboveDenominator() public {
    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.FeeBpsExceedsDenominator.selector, uint16(10_001)));
    new CreditPackSale(address(usdc), feeRecipient, 10_001);
  }

  function test_createGroup_assignsSequentialIdsAndCallerAsOperator() public {
    vm.prank(stranger);
    uint256 secondGroupId = sale.createGroup(stranger, 1, 1);

    assertEq(groupId, 1);
    assertEq(secondGroupId, 2);
    assertEq(sale.getGroup(groupId).operator, operator);
    assertEq(sale.getGroup(secondGroupId).operator, stranger);
    assertTrue(sale.getGroup(groupId).active);
  }

  function test_createGroup_rejectsInvalidTerms() public {
    vm.expectRevert(CreditPackSale.TreasuryCannotBeZeroAddress.selector);
    sale.createGroup(address(0), PACK_PRICE, PACK_CREDITS);

    vm.expectRevert(CreditPackSale.PackPriceCannotBeZero.selector);
    sale.createGroup(treasury, 0, PACK_CREDITS);

    vm.expectRevert(CreditPackSale.PackCreditsCannotBeZero.selector);
    sale.createGroup(treasury, PACK_PRICE, 0);
  }

  function test_purchase_splitsDefaultFeeFromOperatorProceeds() public {
    vm.expectEmit(true, true, true, true, address(sale));
    emit PackPurchased(groupId, player, QUOTE_ID, coinflow, 3, 30, 12_000_000, 600_000, treasury);

    _purchase(coinflow, 3, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient), 600_000);
    assertEq(usdc.balanceOf(treasury), 11_400_000);
    assertEq(usdc.balanceOf(coinflow), 1_000_000_000 - 12_000_000);
    assertEq(usdc.balanceOf(address(sale)), 0);
    assertEq(usdc.balanceOf(player), 0);
    assertTrue(sale.usedQuoteIds(coinflow, QUOTE_ID));
  }

  function test_purchase_usesGroupFeeOverride() public {
    vm.prank(owner);
    sale.setGroupFeeOverride(groupId, true, 250);

    _purchase(coinflow, 1, QUOTE_ID);

    assertEq(sale.feeBpsForGroup(groupId), 250);
    assertEq(usdc.balanceOf(feeRecipient), 100_000);
    assertEq(usdc.balanceOf(treasury), 3_900_000);
  }

  function test_purchase_zeroFeeOverridePaysTreasuryInFull() public {
    vm.prank(owner);
    sale.setGroupFeeOverride(groupId, true, 0);

    _purchase(coinflow, 1, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient), 0);
    assertEq(usdc.balanceOf(treasury), PACK_PRICE);
  }

  function test_purchase_disabledOverrideFallsBackToDefault() public {
    vm.startPrank(owner);
    sale.setGroupFeeOverride(groupId, true, 0);
    sale.setGroupFeeOverride(groupId, false, 9_000);
    vm.stopPrank();

    assertEq(sale.feeBpsForGroup(groupId), DEFAULT_FEE_BPS);
  }

  function test_purchase_fullFeePaysOnlyFeeRecipient() public {
    vm.prank(owner);
    sale.setDefaultFeeBps(10_000);

    _purchase(coinflow, 1, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient), PACK_PRICE);
    assertEq(usdc.balanceOf(treasury), 0);
  }

  function test_purchase_roundsFeeDownInOperatorFavor() public {
    vm.prank(operator);
    sale.updateGroupTerms(groupId, treasury, 19, PACK_CREDITS);

    vm.prank(coinflow);
    sale.purchase(groupId, player, 1, 19, PACK_CREDITS, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient), 0);
    assertEq(usdc.balanceOf(treasury), 19);
  }

  function test_purchase_rejectsReusedQuoteId() public {
    _purchase(coinflow, 1, QUOTE_ID);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.QuoteAlreadyUsed.selector, coinflow, QUOTE_ID));
    _purchase(coinflow, 1, QUOTE_ID);
  }

  function test_purchase_rejectsInvalidInputs() public {
    vm.startPrank(coinflow);

    vm.expectRevert(CreditPackSale.RecipientCannotBeZeroAddress.selector);
    sale.purchase(groupId, address(0), 1, PACK_PRICE, PACK_CREDITS, QUOTE_ID);

    vm.expectRevert(CreditPackSale.QuantityCannotBeZero.selector);
    sale.purchase(groupId, player, 0, PACK_PRICE, PACK_CREDITS, QUOTE_ID);

    vm.expectRevert(CreditPackSale.QuoteIdCannotBeZero.selector);
    sale.purchase(groupId, player, 1, PACK_PRICE, PACK_CREDITS, bytes32(0));

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.GroupDoesNotExist.selector, uint256(99)));
    sale.purchase(99, player, 1, PACK_PRICE, PACK_CREDITS, QUOTE_ID);

    vm.stopPrank();
  }

  function test_purchase_rejectsTermsChangedAfterQuote() public {
    vm.prank(operator);
    sale.updateGroupTerms(groupId, treasury, PACK_PRICE + 1, PACK_CREDITS);

    vm.expectRevert(
      abi.encodeWithSelector(
        CreditPackSale.PackTermsMismatch.selector,
        PACK_PRICE,
        PACK_PRICE + 1,
        PACK_CREDITS,
        PACK_CREDITS
      )
    );
    _purchase(coinflow, 1, QUOTE_ID);
  }

  function test_purchase_rejectsInactiveGroup() public {
    vm.prank(operator);
    sale.setGroupActive(groupId, false);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.GroupNotPurchasable.selector, groupId));
    _purchase(coinflow, 1, QUOTE_ID);
  }

  function test_purchase_rejectsSuspendedGroupEvenIfOperatorReactivates() public {
    vm.prank(owner);
    sale.setGroupSuspended(groupId, true);
    vm.prank(operator);
    sale.setGroupActive(groupId, true);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.GroupNotPurchasable.selector, groupId));
    _purchase(coinflow, 1, QUOTE_ID);
  }

  function test_purchase_rejectsWhilePaused() public {
    vm.prank(owner);
    sale.pause();

    vm.expectRevert("Pausable: paused");
    _purchase(coinflow, 1, QUOTE_ID);
  }

  function test_purchase_isAtomicWhenPayerCannotCoverTotal() public {
    usdc.mint(stranger, PACK_PRICE - 1);
    vm.prank(stranger);
    usdc.approve(address(sale), type(uint256).max);

    vm.expectRevert("ERC20: transfer amount exceeds balance");
    _purchase(stranger, 1, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient), 0);
    assertEq(usdc.balanceOf(stranger), PACK_PRICE - 1);
    assertFalse(sale.usedQuoteIds(stranger, QUOTE_ID));
  }

  function test_operatorFunctions_rejectNonOperator() public {
    vm.startPrank(stranger);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.CallerIsNotGroupOperator.selector, groupId, stranger));
    sale.updateGroupTerms(groupId, stranger, PACK_PRICE, PACK_CREDITS);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.CallerIsNotGroupOperator.selector, groupId, stranger));
    sale.setGroupActive(groupId, false);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.CallerIsNotGroupOperator.selector, groupId, stranger));
    sale.transferGroupOperator(groupId, stranger);

    vm.stopPrank();
  }

  function test_ownerFunctions_rejectNonOwner() public {
    vm.startPrank(operator);

    vm.expectRevert("Ownable: caller is not the owner");
    sale.setGroupFeeOverride(groupId, true, 0);

    vm.expectRevert("Ownable: caller is not the owner");
    sale.setDefaultFeeBps(0);

    vm.expectRevert("Ownable: caller is not the owner");
    sale.setGroupSuspended(groupId, true);

    vm.expectRevert("Ownable: caller is not the owner");
    sale.setFeeRecipient(operator);

    vm.expectRevert("Ownable: caller is not the owner");
    sale.pause();

    vm.stopPrank();
  }

  function test_ownerFunctions_rejectInvalidValues() public {
    vm.startPrank(owner);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.FeeBpsExceedsDenominator.selector, uint16(10_001)));
    sale.setDefaultFeeBps(10_001);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.FeeBpsExceedsDenominator.selector, uint16(10_001)));
    sale.setGroupFeeOverride(groupId, true, 10_001);

    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.GroupDoesNotExist.selector, uint256(99)));
    sale.setGroupFeeOverride(99, true, 0);

    vm.expectRevert(CreditPackSale.FeeRecipientCannotBeZeroAddress.selector);
    sale.setFeeRecipient(address(0));

    vm.stopPrank();
  }

  function test_transferGroupOperator_movesControl() public {
    vm.prank(operator);
    sale.transferGroupOperator(groupId, stranger);

    vm.prank(stranger);
    sale.updateGroupTerms(groupId, stranger, PACK_PRICE, PACK_CREDITS);

    assertEq(sale.getGroup(groupId).operator, stranger);
    assertEq(sale.getGroup(groupId).treasury, stranger);

    vm.prank(operator);
    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.CallerIsNotGroupOperator.selector, groupId, operator));
    sale.setGroupActive(groupId, false);
  }

  function testFuzz_purchase_feeAndProceedsSumToGross(uint96 _packPrice, uint8 _quantity, uint16 _feeBps) public {
    vm.assume(_packPrice > 0 && _quantity > 0);
    uint16 feeBps = uint16(bound(_feeBps, 0, 10_000));
    uint256 grossAmount = uint256(_packPrice) * _quantity;

    vm.prank(owner);
    sale.setDefaultFeeBps(feeBps);
    vm.prank(operator);
    sale.updateGroupTerms(groupId, treasury, _packPrice, PACK_CREDITS);
    usdc.mint(coinflow, grossAmount);

    vm.prank(coinflow);
    sale.purchase(groupId, player, _quantity, _packPrice, PACK_CREDITS, QUOTE_ID);

    assertEq(usdc.balanceOf(feeRecipient) + usdc.balanceOf(treasury), grossAmount);
    assertEq(usdc.balanceOf(feeRecipient), (grossAmount * feeBps) / 10_000);
  }

  function test_purchase_otherPayerCannotBurnCoinflowQuoteId() public {
    vm.prank(stranger);
    uint256 attackerGroupId = sale.createGroup(stranger, 1, 1);
    usdc.mint(stranger, 1);
    vm.startPrank(stranger);
    usdc.approve(address(sale), 1);
    sale.purchase(attackerGroupId, stranger, 1, 1, 1, QUOTE_ID);
    vm.stopPrank();

    _purchase(coinflow, 1, QUOTE_ID);

    assertTrue(sale.usedQuoteIds(stranger, QUOTE_ID));
    assertTrue(sale.usedQuoteIds(coinflow, QUOTE_ID));
    assertEq(usdc.balanceOf(treasury), PACK_PRICE - (PACK_PRICE * DEFAULT_FEE_BPS) / 10_000);
  }

  function test_purchase_paysUpdatedTreasury() public {
    address newTreasury = makeAddr("newTreasury");
    vm.prank(operator);
    sale.updateGroupTerms(groupId, newTreasury, PACK_PRICE, PACK_CREDITS);

    _purchase(coinflow, 1, QUOTE_ID);

    assertEq(usdc.balanceOf(treasury), 0);
    assertEq(usdc.balanceOf(newTreasury), 3_800_000);
  }

  function test_unpause_restoresPurchases() public {
    vm.startPrank(owner);
    sale.pause();
    sale.unpause();
    vm.stopPrank();

    _purchase(coinflow, 1, QUOTE_ID);

    assertEq(usdc.balanceOf(treasury), 3_800_000);
  }

  function test_ownership_requiresAcceptanceAndCannotBeRenounced() public {
    address newOwner = makeAddr("newOwner");
    vm.prank(owner);
    sale.transferOwnership(newOwner);
    assertEq(sale.owner(), owner);

    vm.prank(newOwner);
    sale.acceptOwnership();
    assertEq(sale.owner(), newOwner);

    vm.prank(newOwner);
    vm.expectRevert(CreditPackSale.RenounceOwnershipDisabled.selector);
    sale.renounceOwnership();
  }

  function test_adminInputs_rejectZeroOperatorAndUnknownGroup() public {
    vm.prank(operator);
    vm.expectRevert(CreditPackSale.OperatorCannotBeZeroAddress.selector);
    sale.transferGroupOperator(groupId, address(0));

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(CreditPackSale.GroupDoesNotExist.selector, uint256(99)));
    sale.setGroupSuspended(99, true);
  }
}
