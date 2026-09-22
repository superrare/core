// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "solady/utils/DateTimeLib.sol";

/// @title SuperRare creator memberships
/// @notice Fixed-price monthly USDC payments, paid directly to an artist and treasury.
/// @dev Membership identity and content access remain account-based off chain. No NFT is issued.
/// The operator can authorize a first payment and cancel, but cannot alter an enrolled member's
/// price, creator, treasury or cadence. Renewals are permissionless and never charge arrears.
contract CreatorMemberships is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
  using SafeERC20 for IERC20;

  uint256 public constant FEE_BASIS_POINTS = 500;
  uint256 public constant RENEWAL_WINDOW = 7 days;
  bytes32 public constant TERMS_TYPEHASH =
    keccak256(
      "MembershipTerms(bytes32 subscriptionId,address payer,address creator,uint256 amount,uint256 validUntil)"
    );

  IERC20 public immutable usdc;
  address public immutable treasury;
  address public operator;

  struct MembershipTerms {
    bytes32 subscriptionId;
    address payer;
    address creator;
    uint256 amount;
    uint256 validUntil;
  }

  struct Subscription {
    address payer;
    address creator;
    uint256 amount;
    uint256 paidThrough;
    bool canceled;
  }

  mapping(bytes32 => Subscription) public subscriptions;
  mapping(address => mapping(address => bytes32)) public currentSubscription;
  mapping(address => bool) public endedCreators;

  event MembershipPaid(
    bytes32 indexed subscriptionId,
    address indexed payer,
    address indexed creator,
    uint256 amount,
    uint256 platformFee,
    uint256 periodStart,
    uint256 periodEnd
  );
  event SubscriptionCanceled(bytes32 indexed subscriptionId);
  event CreatorEnded(address indexed creator);
  event OperatorChanged(address indexed previousOperator, address indexed newOperator);

  error InvalidConfiguration();
  error InvalidTerms();
  error Unauthorized();
  error AlreadySubscribed();
  error RenewalUnavailable();

  constructor(
    address token,
    address feeRecipient,
    address initialOperator,
    address initialOwner
  ) EIP712("SuperRare Creator Memberships", "1") {
    if (
      token.code.length == 0 ||
      IERC20Metadata(token).decimals() != 6 ||
      feeRecipient == address(0) ||
      initialOperator == address(0) ||
      initialOwner == address(0)
    ) revert InvalidConfiguration();
    usdc = IERC20(token);
    treasury = feeRecipient;
    operator = initialOperator;
    _transferOwnership(initialOwner);
  }

  /// @notice Authorize the immutable monthly terms and pay for the first calendar month.
  /// @dev The wallet must separately approve this contract's USDC spending limit.
  function subscribe(MembershipTerms calldata terms, bytes calldata signature) external whenNotPaused nonReentrant {
    if (
      terms.subscriptionId == bytes32(0) ||
      terms.payer != msg.sender ||
      terms.creator == address(0) ||
      terms.creator == msg.sender ||
      endedCreators[terms.creator] ||
      terms.validUntil < block.timestamp ||
      terms.amount < 1e6 ||
      terms.amount > 500e6 ||
      terms.amount % 10_000 != 0
    ) revert InvalidTerms();
    if (subscriptions[terms.subscriptionId].payer != address(0)) revert AlreadySubscribed();
    if (
      ECDSA.recover(
        _hashTypedDataV4(
          keccak256(
            abi.encode(TERMS_TYPEHASH, terms.subscriptionId, terms.payer, terms.creator, terms.amount, terms.validUntil)
          )
        ),
        signature
      ) != operator
    ) revert Unauthorized();

    Subscription storage previous = subscriptions[currentSubscription[msg.sender][terms.creator]];
    if (
      previous.payer != address(0) &&
      (previous.paidThrough > block.timestamp ||
        (!previous.canceled && block.timestamp <= previous.paidThrough + RENEWAL_WINDOW))
    ) revert AlreadySubscribed();

    uint256 periodEnd = DateTimeLib.addMonths(block.timestamp, 1);
    subscriptions[terms.subscriptionId] = Subscription(msg.sender, terms.creator, terms.amount, periodEnd, false);
    currentSubscription[msg.sender][terms.creator] = terms.subscriptionId;
    _collect(terms.subscriptionId, msg.sender, terms.creator, terms.amount, block.timestamp, periodEnd);
  }

  /// @notice Renew one due period. A stale retry cannot collect another payment.
  /// @dev After a failed payment there is no paid access until recovery. Recovery purchases
  /// a complete calendar month from confirmation, rather than charging for the unpaid gap.
  function renew(bytes32 subscriptionId, uint256 expectedPaidThrough) external whenNotPaused nonReentrant {
    Subscription storage subscription = subscriptions[subscriptionId];
    if (
      subscription.payer == address(0) ||
      subscription.canceled ||
      endedCreators[subscription.creator] ||
      currentSubscription[subscription.payer][subscription.creator] != subscriptionId ||
      subscription.paidThrough != expectedPaidThrough ||
      block.timestamp < subscription.paidThrough ||
      block.timestamp > subscription.paidThrough + RENEWAL_WINDOW
    ) revert RenewalUnavailable();
    uint256 periodEnd = DateTimeLib.addMonths(block.timestamp, 1);
    subscription.paidThrough = periodEnd;
    _collect(subscriptionId, subscription.payer, subscription.creator, subscription.amount, block.timestamp, periodEnd);
  }

  /// @notice Stop renewals without changing the already-paid access boundary.
  /// @dev A member can cancel directly even if SuperRare's service is unavailable or paused.
  function cancel(bytes32 subscriptionId) external {
    Subscription storage subscription = subscriptions[subscriptionId];
    if (subscription.payer == address(0) || (msg.sender != subscription.payer && msg.sender != operator))
      revert Unauthorized();
    if (subscription.canceled) return;
    subscription.canceled = true;
    emit SubscriptionCanceled(subscriptionId);
  }

  /// @notice Permanently stop an artist's new subscriptions and existing renewals.
  function endCreator(address creator) external {
    if (creator == address(0) || (msg.sender != creator && msg.sender != operator)) revert Unauthorized();
    if (endedCreators[creator]) return;
    endedCreators[creator] = true;
    emit CreatorEnded(creator);
  }

  function setOperator(address newOperator) external onlyOwner {
    if (newOperator == address(0)) revert InvalidConfiguration();
    emit OperatorChanged(operator, newOperator);
    operator = newOperator;
  }

  function pause() external onlyOwner {
    _pause();
  }
  function unpause() external onlyOwner {
    _unpause();
  }

  function _collect(
    bytes32 subscriptionId,
    address payer,
    address creator,
    uint256 amount,
    uint256 start,
    uint256 end
  ) internal {
    uint256 fee = (amount * FEE_BASIS_POINTS) / 10_000;
    usdc.safeTransferFrom(payer, creator, amount - fee);
    usdc.safeTransferFrom(payer, treasury, fee);
    emit MembershipPaid(subscriptionId, payer, creator, amount, fee, start, end);
  }
}
