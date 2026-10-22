// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {Pausable} from "openzeppelin-contracts/security/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract CreditPackSale is Ownable2Step, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  uint16 public constant BPS_DENOMINATOR = 10_000;

  struct CreditGroup {
    address operator;
    address treasury;
    uint256 packPrice;
    uint256 packCredits;
    bool active;
    bool suspended;
  }

  struct FeeOverride {
    bool enabled;
    uint16 feeBps;
  }

  error CurrencyCannotBeZeroAddress();
  error FeeRecipientCannotBeZeroAddress();
  error OperatorCannotBeZeroAddress();
  error TreasuryCannotBeZeroAddress();
  error RecipientCannotBeZeroAddress();
  error PackPriceCannotBeZero();
  error PackCreditsCannotBeZero();
  error QuantityCannotBeZero();
  error QuoteIdCannotBeZero();
  error FeeBpsExceedsDenominator(uint16 feeBps);
  error GroupDoesNotExist(uint256 groupId);
  error CallerIsNotGroupOperator(uint256 groupId, address caller);
  error GroupNotPurchasable(uint256 groupId);
  error QuoteAlreadyUsed(address payer, bytes32 quoteId);
  error RenounceOwnershipDisabled();
  error PackTermsMismatch(
    uint256 expectedPackPrice,
    uint256 packPrice,
    uint256 expectedPackCredits,
    uint256 packCredits
  );

  event GroupCreated(
    uint256 indexed groupId,
    address indexed operator,
    address treasury,
    uint256 packPrice,
    uint256 packCredits
  );
  event GroupTermsUpdated(uint256 indexed groupId, address treasury, uint256 packPrice, uint256 packCredits);
  event GroupActiveUpdated(uint256 indexed groupId, bool active);
  event GroupSuspendedUpdated(uint256 indexed groupId, bool suspended);
  event GroupOperatorTransferred(
    uint256 indexed groupId,
    address indexed previousOperator,
    address indexed newOperator
  );
  event DefaultFeeBpsUpdated(uint16 feeBps);
  event GroupFeeOverrideUpdated(uint256 indexed groupId, bool enabled, uint16 feeBps);
  event FeeRecipientUpdated(address feeRecipient);
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

  IERC20 public immutable currency;
  address public feeRecipient;
  uint16 public defaultFeeBps;
  uint256 public groupCount;

  mapping(uint256 => CreditGroup) private groups;
  mapping(uint256 => FeeOverride) private feeOverrides;
  mapping(address => mapping(bytes32 => bool)) public usedQuoteIds;

  constructor(address _currency, address _feeRecipient, uint16 _defaultFeeBps) {
    if (_currency == address(0)) {
      revert CurrencyCannotBeZeroAddress();
    }
    currency = IERC20(_currency);
    _setFeeRecipient(_feeRecipient);
    _setDefaultFeeBps(_defaultFeeBps);
  }

  modifier onlyGroupOperator(uint256 _groupId) {
    if (groups[_groupId].operator != msg.sender) {
      revert CallerIsNotGroupOperator(_groupId, msg.sender);
    }
    _;
  }

  function createGroup(address _treasury, uint256 _packPrice, uint256 _packCredits) external returns (uint256 groupId) {
    _validateTerms(_treasury, _packPrice, _packCredits);
    groupId = ++groupCount;
    groups[groupId] = CreditGroup({
      operator: msg.sender,
      treasury: _treasury,
      packPrice: _packPrice,
      packCredits: _packCredits,
      active: true,
      suspended: false
    });
    emit GroupCreated(groupId, msg.sender, _treasury, _packPrice, _packCredits);
  }

  function updateGroupTerms(
    uint256 _groupId,
    address _treasury,
    uint256 _packPrice,
    uint256 _packCredits
  ) external onlyGroupOperator(_groupId) {
    _validateTerms(_treasury, _packPrice, _packCredits);
    CreditGroup storage group = groups[_groupId];
    group.treasury = _treasury;
    group.packPrice = _packPrice;
    group.packCredits = _packCredits;
    emit GroupTermsUpdated(_groupId, _treasury, _packPrice, _packCredits);
  }

  function setGroupActive(uint256 _groupId, bool _active) external onlyGroupOperator(_groupId) {
    groups[_groupId].active = _active;
    emit GroupActiveUpdated(_groupId, _active);
  }

  function transferGroupOperator(uint256 _groupId, address _newOperator) external onlyGroupOperator(_groupId) {
    if (_newOperator == address(0)) {
      revert OperatorCannotBeZeroAddress();
    }
    groups[_groupId].operator = _newOperator;
    emit GroupOperatorTransferred(_groupId, msg.sender, _newOperator);
  }

  function setGroupSuspended(uint256 _groupId, bool _suspended) external onlyOwner {
    _requireGroupExists(_groupId);
    groups[_groupId].suspended = _suspended;
    emit GroupSuspendedUpdated(_groupId, _suspended);
  }

  function setGroupFeeOverride(uint256 _groupId, bool _enabled, uint16 _feeBps) external onlyOwner {
    _requireGroupExists(_groupId);
    if (_feeBps > BPS_DENOMINATOR) {
      revert FeeBpsExceedsDenominator(_feeBps);
    }
    feeOverrides[_groupId] = FeeOverride({enabled: _enabled, feeBps: _enabled ? _feeBps : 0});
    emit GroupFeeOverrideUpdated(_groupId, _enabled, _enabled ? _feeBps : 0);
  }

  function setDefaultFeeBps(uint16 _feeBps) external onlyOwner {
    _setDefaultFeeBps(_feeBps);
  }

  function setFeeRecipient(address _feeRecipient) external onlyOwner {
    _setFeeRecipient(_feeRecipient);
  }

  function renounceOwnership() public view override onlyOwner {
    revert RenounceOwnershipDisabled();
  }

  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  function purchase(
    uint256 _groupId,
    address _recipient,
    uint256 _quantity,
    uint256 _expectedPackPrice,
    uint256 _expectedPackCredits,
    bytes32 _quoteId
  ) external nonReentrant whenNotPaused {
    if (_recipient == address(0)) {
      revert RecipientCannotBeZeroAddress();
    }
    if (_quantity == 0) {
      revert QuantityCannotBeZero();
    }
    if (_quoteId == bytes32(0)) {
      revert QuoteIdCannotBeZero();
    }
    if (usedQuoteIds[msg.sender][_quoteId]) {
      revert QuoteAlreadyUsed(msg.sender, _quoteId);
    }

    CreditGroup memory group = groups[_groupId];
    if (group.operator == address(0)) {
      revert GroupDoesNotExist(_groupId);
    }
    if (!group.active || group.suspended) {
      revert GroupNotPurchasable(_groupId);
    }
    if (group.packPrice != _expectedPackPrice || group.packCredits != _expectedPackCredits) {
      revert PackTermsMismatch(_expectedPackPrice, group.packPrice, _expectedPackCredits, group.packCredits);
    }

    usedQuoteIds[msg.sender][_quoteId] = true;

    uint256 grossAmount = group.packPrice * _quantity;
    uint256 feeAmount = (grossAmount * feeBpsForGroup(_groupId)) / BPS_DENOMINATOR;
    uint256 credits = group.packCredits * _quantity;

    if (feeAmount > 0) {
      currency.safeTransferFrom(msg.sender, feeRecipient, feeAmount);
    }
    if (grossAmount > feeAmount) {
      currency.safeTransferFrom(msg.sender, group.treasury, grossAmount - feeAmount);
    }

    emit PackPurchased(
      _groupId,
      _recipient,
      _quoteId,
      msg.sender,
      _quantity,
      credits,
      grossAmount,
      feeAmount,
      group.treasury
    );
  }

  function getGroup(uint256 _groupId) external view returns (CreditGroup memory) {
    _requireGroupExists(_groupId);
    return groups[_groupId];
  }

  function feeBpsForGroup(uint256 _groupId) public view returns (uint16) {
    FeeOverride memory feeOverride = feeOverrides[_groupId];
    return feeOverride.enabled ? feeOverride.feeBps : defaultFeeBps;
  }

  function _validateTerms(address _treasury, uint256 _packPrice, uint256 _packCredits) private pure {
    if (_treasury == address(0)) {
      revert TreasuryCannotBeZeroAddress();
    }
    if (_packPrice == 0) {
      revert PackPriceCannotBeZero();
    }
    if (_packCredits == 0) {
      revert PackCreditsCannotBeZero();
    }
  }

  function _requireGroupExists(uint256 _groupId) private view {
    if (groups[_groupId].operator == address(0)) {
      revert GroupDoesNotExist(_groupId);
    }
  }

  function _setDefaultFeeBps(uint16 _feeBps) private {
    if (_feeBps > BPS_DENOMINATOR) {
      revert FeeBpsExceedsDenominator(_feeBps);
    }
    defaultFeeBps = _feeBps;
    emit DefaultFeeBpsUpdated(_feeBps);
  }

  function _setFeeRecipient(address _feeRecipient) private {
    if (_feeRecipient == address(0)) {
      revert FeeRecipientCannotBeZeroAddress();
    }
    feeRecipient = _feeRecipient;
    emit FeeRecipientUpdated(_feeRecipient);
  }
}
