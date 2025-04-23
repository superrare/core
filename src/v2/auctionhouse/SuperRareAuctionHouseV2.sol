// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";

import {MarketUtilsV2} from "../utils/MarketUtilsV2.sol";
import {MarketConfigV2} from "../utils/MarketConfigV2.sol";
import {ISuperRareAuctionHouseV2} from "./ISuperRareAuctionHouseV2.sol";

/// @author SuperRare Labs
/// @title SuperRareAuctionHouseV2
/// @notice The logic for all functions related to the SuperRareAuctionHouseV2.
/// @dev This contract consolidates standard auction functionality from the SuperRare Bazaar
/// with the existing Merkle auction features, ensuring full adoption of MarketUtilsV2.
contract SuperRareAuctionHouseV2 is ISuperRareAuctionHouseV2, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using EnumerableSet for EnumerableSet.Bytes32Set;
  using MarketConfigV2 for MarketConfigV2.Config;
  using MarketUtilsV2 for MarketConfigV2.Config;

  // Constants
  bytes32 public constant NO_AUCTION = bytes32(0);
  bytes32 public constant SCHEDULED_AUCTION = keccak256("SCHEDULED_AUCTION");
  bytes32 public constant COLDIE_AUCTION = keccak256("COLDIE_AUCTION");

  // Config
  MarketConfigV2.Config internal marketConfig;

  // Standard Auction Storage
  mapping(address => mapping(uint256 => Auction)) public tokenAuctions;
  mapping(address => mapping(uint256 => Bid)) public auctionBids;

  // Auction Settings
  uint256 public minimumBidIncreasePercentage;
  uint256 public maxAuctionLength;
  uint256 public auctionLengthExtension;

  // Merkle Auction Storage
  // Mapping from creator to all their auction Merkle roots
  mapping(address => EnumerableSet.Bytes32Set) private creatorAuctionMerkleRoots;

  // Mapping from (creator, root) to MerkleAuctionConfig
  mapping(address => mapping(bytes32 => MerkleAuctionConfig)) public creatorRootToConfig;

  // Mapping from (creator, root) to nonce for that root
  mapping(address => mapping(bytes32 => uint256)) private creatorRootNonce;

  // Mapping of keccak256(creator, root, tokenContract, tokenId) to nonce
  // Key is computed as: keccak256(abi.encodePacked(creator, root, tokenContract, tokenId))
  mapping(bytes32 => uint256) private tokenAuctionNonce;

  /**
   * @dev Initializer function
   */
  function initialize(
    address _marketplaceSettings,
    address _royaltyEngine,
    address _spaceOperatorRegistry,
    address _approvedTokenRegistry,
    address _payments,
    address _stakingRegistry,
    address _stakingSettings,
    address _networkBeneficiary,
    address _erc20ApprovalManager,
    address _erc721ApprovalManager
  ) public initializer {
    require(_marketplaceSettings != address(0), "initialize::marketplaceSettings cannot be 0 address");
    require(_royaltyEngine != address(0), "initialize::royaltyEngine cannot be 0 address");
    require(_spaceOperatorRegistry != address(0), "initialize::spaceOperatorRegistry cannot be 0 address");
    require(_approvedTokenRegistry != address(0), "initialize::approvedTokenRegistry cannot be 0 address");
    require(_payments != address(0), "initialize::payments cannot be 0 address");
    require(_stakingRegistry != address(0), "initialize::stakingRegistry cannot be 0 address");
    require(_stakingSettings != address(0), "initialize::stakingSettings cannot be 0 address");
    require(_networkBeneficiary != address(0), "initialize::networkBeneficiary cannot be 0 address");
    require(_erc20ApprovalManager != address(0), "initialize::erc20ApprovalManager cannot be 0 address");
    require(_erc721ApprovalManager != address(0), "initialize::erc721ApprovalManager cannot be 0 address");

    // Initialize market config
    marketConfig = MarketConfigV2.generateMarketConfig(
      _networkBeneficiary,
      _marketplaceSettings,
      _spaceOperatorRegistry,
      _royaltyEngine,
      _payments,
      _approvedTokenRegistry,
      _stakingSettings,
      _stakingRegistry,
      _erc20ApprovalManager,
      _erc721ApprovalManager
    );

    // Initialize auction settings
    minimumBidIncreasePercentage = 1;
    maxAuctionLength = 7 days;
    auctionLengthExtension = 15 minutes;

    __Ownable_init();
    __ReentrancyGuard_init();
  }

  /// @notice Fallback function to prevent accidental ETH sends to this contract
  receive() external payable {
    revert("ETH payment not accepted directly");
  }

  /*//////////////////////////////////////////////////////////////
                      ADMIN FUNCTIONS 
  //////////////////////////////////////////////////////////////*/

  /// @notice Sets the minimum bid increase percentage
  /// @param _minimumBidIncreasePercentage The new minimum bid increase percentage
  function setMinimumBidIncreasePercentage(uint8 _minimumBidIncreasePercentage) external onlyOwner {
    minimumBidIncreasePercentage = _minimumBidIncreasePercentage;
  }

  /// @notice Sets the maximum auction length
  /// @param _maxAuctionLength The new maximum auction length in seconds
  function setMaxAuctionLength(uint256 _maxAuctionLength) external onlyOwner {
    maxAuctionLength = _maxAuctionLength;
  }

  /// @notice Sets the auction length extension
  /// @param _auctionLengthExtension The new auction length extension in seconds
  function setAuctionLengthExtension(uint256 _auctionLengthExtension) external onlyOwner {
    auctionLengthExtension = _auctionLengthExtension;
  }

  /*//////////////////////////////////////////////////////////////
                      STANDARD AUCTION FUNCTIONS 
  //////////////////////////////////////////////////////////////*/

  /// @notice Configures an Auction for a given asset.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function configureAuction(
    bytes32 _auctionType,
    address _originContract,
    uint256 _tokenId,
    uint256 _startingAmount,
    address _currencyAddress,
    uint256 _lengthOfAuction,
    uint256 _startTime,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external override {
    // Check if currency is approved
    MarketUtilsV2.checkIfCurrencyIsApproved(marketConfig, _currencyAddress);

    // Get current auction data if it exists
    Auction memory auction = tokenAuctions[_originContract][_tokenId];
    IERC721 erc721 = IERC721(_originContract);

    // Allow for re-configuring a scheduled auction that has not started
    if (erc721.ownerOf(_tokenId) == address(this) && auction.startingTime > block.timestamp) {
      // Verify sender is auction creator
      require(auction.auctionCreator == msg.sender, "configureAuction::Must be auction creator");
    } else {
      // Verify sender is token owner
      MarketUtilsV2.senderMustBeTokenOwner(_originContract, _tokenId);
    }

    // Verify token is approved for marketplace
    marketConfig.addressMustHaveMarketplaceApprovedForNFT(msg.sender, _originContract, _tokenId);

    // Validate split configuration
    MarketUtilsV2.checkSplits(_splitAddresses, _splitRatios);

    // Validate auction type
    _checkValidAuctionType(_auctionType);

    // Check auction parameters
    require(_lengthOfAuction <= maxAuctionLength, "configureAuction::Auction too long");
    require(_lengthOfAuction > 0, "configureAuction::Length must be > 0");

    // Ensure no current bid exists
    Bid memory staleBid = auctionBids[_originContract][_tokenId];
    require(staleBid.bidder == address(0), "configureAuction::Bid shouldn't exist");

    // Check auction type specific requirements
    if (_auctionType == COLDIE_AUCTION) {
      require(_startingAmount > 0, "configureAuction::Coldie starting price must be > 0");
    } else if (_auctionType == SCHEDULED_AUCTION) {
      require(_startTime > block.timestamp, "configureAuction::Scheduled auction cannot start in past");
    }

    // Ensure starting amount is within acceptable range
    require(
      _startingAmount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(),
      "configureAuction::Cannot set starting price higher than max value"
    );

    // Create auction
    tokenAuctions[_originContract][_tokenId] = Auction({
      auctionCreator: payable(msg.sender),
      creationBlock: block.number,
      startingTime: _auctionType == COLDIE_AUCTION ? 0 : _startTime,
      lengthOfAuction: _lengthOfAuction,
      currencyAddress: _currencyAddress,
      minimumBid: _startingAmount,
      auctionType: _auctionType,
      splitRecipients: _splitAddresses,
      splitRatios: _splitRatios
    });

    // Transfer token to this contract if scheduled auction
    if (_auctionType == SCHEDULED_AUCTION && erc721.ownerOf(_tokenId) != address(this)) {
      MarketUtilsV2.transferERC721(marketConfig, _originContract, msg.sender, address(this), _tokenId);
    }

    emit NewAuction(
      _originContract,
      _tokenId,
      msg.sender,
      _currencyAddress,
      _startTime,
      _startingAmount,
      _lengthOfAuction
    );
  }

  /// @notice Cancels a configured Auction that has not started.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function cancelAuction(address _originContract, uint256 _tokenId) external override {
    // Get auction details
    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    // Verify auction exists
    require(auction.auctionType != NO_AUCTION, "cancelAuction::Must have an auction configured");

    // Verify auction has not started
    require(
      auction.startingTime == 0 || block.timestamp < auction.startingTime,
      "cancelAuction::Auction must not have started"
    );

    // Get token owner
    IERC721 erc721 = IERC721(_originContract);

    // Check permissions - only auction creator can cancel
    // This is a more restrictive model than the original, following the task checklist's recommendation
    require(auction.auctionCreator == msg.sender, "cancelAuction::Must be auction creator");

    // Delete auction from storage
    delete tokenAuctions[_originContract][_tokenId];

    // Return token if in contract
    if (erc721.ownerOf(_tokenId) == address(this)) {
      erc721.transferFrom(address(this), msg.sender, _tokenId);
    }

    // Verify token was returned
    require(erc721.ownerOf(_tokenId) == msg.sender, "cancelAuction::Token transfer failed");

    // Emit event
    emit CancelAuction(_originContract, _tokenId, auction.auctionCreator);
  }

  /// @notice Places a bid on a valid auction.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function bid(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount
  ) external payable override nonReentrant {
    // Calculate required amount (bid + marketplace fee)
    uint256 requiredAmount = _amount + marketConfig.marketplaceSettings.calculateMarketplaceFee(_amount);

    // Check that the sender has approved the marketplace for this amount
    marketConfig.senderMustHaveMarketplaceApproved(_currencyAddress, requiredAmount);

    // Get the current auction
    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    // Verify auction exists
    require(auction.auctionType != NO_AUCTION, "bid::Must have a current auction");

    // Verify bidder is not the auction creator
    require(auction.auctionCreator != msg.sender, "bid::Cannot bid on your own auction");

    // Verify auction has started
    require(block.timestamp >= auction.startingTime, "bid::Auction not active");

    // For scheduled auctions, verify auction has not ended
    if (auction.startingTime > 0) {
      require(block.timestamp < auction.startingTime + auction.lengthOfAuction, "bid::Auction has ended");
    }

    // Verify bid currency matches auction currency
    require(_currencyAddress == auction.currencyAddress, "bid::Currency does not match auction currency");

    // Verify bid amount is valid
    require(_amount >= auction.minimumBid, "bid::Bid amount too low");
    require(_amount > 0, "bid::Bid amount must be greater than 0");
    require(_amount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(), "bid::Bid exceeds max value");

    // Get current bid
    Bid memory currentBid = auctionBids[_originContract][_tokenId];
    address previousBidder = currentBid.bidder;

    // If not first bid, verify minimum increase percentage
    if (previousBidder != address(0)) {
      uint256 minBidIncrease = (currentBid.amount * minimumBidIncreasePercentage) / 100;
      require(_amount >= currentBid.amount + minBidIncrease, "bid::Must increase bid by minimum percentage");
    }

    // Transfer tokens for bid
    marketConfig.checkAmountAndTransfer(_currencyAddress, requiredAmount);

    // Calculate auction extension if needed
    uint256 newAuctionLength = 0;

    // If close to end, extend auction
    if (auction.startingTime > 0) {
      uint256 timeLeft = (auction.startingTime + auction.lengthOfAuction) - block.timestamp;

      if (timeLeft < auctionLengthExtension) {
        newAuctionLength = auction.lengthOfAuction + auctionLengthExtension - timeLeft;

        // Update auction length
        tokenAuctions[_originContract][_tokenId].lengthOfAuction = newAuctionLength;
      }
    }

    // For first bid on a Coldie auction
    if (previousBidder == address(0) && auction.auctionType == COLDIE_AUCTION) {
      // Transfer token from auction creator to this contract
      if (IERC721(_originContract).ownerOf(_tokenId) == auction.auctionCreator) {
        marketConfig.transferERC721(_originContract, auction.auctionCreator, address(this), _tokenId);
      }
    }

    // Refund previous bidder if exists
    if (previousBidder != address(0)) {
      marketConfig.refund(
        currentBid.currencyAddress,
        currentBid.amount,
        currentBid.marketplaceFeeAtTime,
        previousBidder
      );
    }

    // Record bid
    auctionBids[_originContract][_tokenId] = Bid({
      bidder: msg.sender,
      currencyAddress: _currencyAddress,
      amount: _amount,
      marketplaceFeeAtTime: marketConfig.marketplaceSettings.getMarketplaceFeePercentage()
    });

    // Emit event
    emit AuctionBid(
      _originContract,
      msg.sender,
      _tokenId,
      _currencyAddress,
      _amount,
      previousBidder == address(0), // firstBid
      marketConfig.marketplaceSettings.getMarketplaceFeePercentage(),
      previousBidder
    );
  }

  /// @notice Settles an auction that has ended.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function settleAuction(address _originContract, uint256 _tokenId) external override {
    // Get auction and bid
    Auction memory auction = tokenAuctions[_originContract][_tokenId];
    Bid memory currentBid = auctionBids[_originContract][_tokenId];

    // Verify auction exists
    require(auction.auctionType != NO_AUCTION, "settleAuction::No auction exists");

    // Verify auction has ended
    require(block.timestamp >= auction.startingTime + auction.lengthOfAuction, "settleAuction::Auction has not ended");

    // Delete auction and bid from storage
    delete tokenAuctions[_originContract][_tokenId];
    delete auctionBids[_originContract][_tokenId];

    if (currentBid.bidder != address(0)) {
      // Transfer token to winning bidder
      IERC721(_originContract).transferFrom(address(this), currentBid.bidder, _tokenId);

      // Execute payout
      marketConfig.payout(
        _originContract,
        _tokenId,
        currentBid.currencyAddress,
        currentBid.amount,
        auction.auctionCreator,
        auction.splitRecipients,
        auction.splitRatios
      );
    } else {
      // If no bids, return token to creator
      IERC721(_originContract).transferFrom(address(this), auction.auctionCreator, _tokenId);
    }

    // Emit event
    emit AuctionSettled(
      _originContract,
      _tokenId,
      auction.auctionCreator,
      currentBid.bidder,
      currentBid.amount,
      currentBid.marketplaceFeeAtTime
    );
  }

  /// @notice Grabs the current auction details for a token.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getAuctionDetails(
    address _originContract,
    uint256 _tokenId
  )
    external
    view
    override
    returns (address, uint256, uint256, uint256, address, uint256, bytes32, address payable[] memory, uint8[] memory)
  {
    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    return (
      auction.auctionCreator,
      auction.creationBlock,
      auction.startingTime,
      auction.lengthOfAuction,
      auction.currencyAddress,
      auction.minimumBid,
      auction.auctionType,
      auction.splitRecipients,
      auction.splitRatios
    );
  }

  /*//////////////////////////////////////////////////////////////
                      MERKLE AUCTION FUNCTIONS 
  //////////////////////////////////////////////////////////////*/

  /// @notice Registers a new Merkle root for auction configuration
  /// @inheritdoc ISuperRareAuctionHouseV2
  function registerAuctionMerkleRoot(
    bytes32 merkleRoot,
    address currency,
    uint256 startingAmount,
    uint256 duration,
    address payable[] calldata splitAddresses,
    uint8[] calldata splitRatios
  ) external override {
    // Check if currency is approved
    marketConfig.checkIfCurrencyIsApproved(currency);

    // Validate split configuration
    MarketUtilsV2.checkSplits(splitAddresses, splitRatios);

    // Verify duration is not too long
    require(duration <= maxAuctionLength, "registerAuctionMerkleRoot::Duration too long");

    // Verify starting amount is valid
    require(
      startingAmount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(),
      "registerAuctionMerkleRoot::Starting amount exceeds maximum value"
    );

    // Add root to user's set of roots
    creatorAuctionMerkleRoots[msg.sender].add(merkleRoot);

    // Calculate new nonce
    uint256 newNonce = creatorRootNonce[msg.sender][merkleRoot] + 1;
    creatorRootNonce[msg.sender][merkleRoot] = newNonce;

    creatorRootToConfig[msg.sender][merkleRoot] = MerkleAuctionConfig({
      currency: currency,
      startingAmount: startingAmount,
      duration: duration,
      splitAddresses: splitAddresses,
      splitRatios: splitRatios,
      nonce: newNonce
    });

    emit AuctionMerkleRootRegistered(msg.sender, merkleRoot, currency, startingAmount, duration, newNonce);
  }

  /// @notice Cancels a previously registered Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function cancelAuctionMerkleRoot(bytes32 root) external override {
    // Check if caller owns the root
    require(creatorAuctionMerkleRoots[msg.sender].contains(root), "cancelAuctionMerkleRoot::Not root owner");

    // Remove root from user's set
    creatorAuctionMerkleRoots[msg.sender].remove(root);

    // Clean up config data (note: we keep the nonce for security)
    delete creatorRootToConfig[msg.sender][root];

    // Emit event
    emit AuctionMerkleRootCancelled(msg.sender, root);
  }

  /// @notice Places a bid using a Merkle proof to verify token inclusion
  /// @inheritdoc ISuperRareAuctionHouseV2
  function bidWithAuctionMerkleProof(
    address originContract,
    uint256 tokenId,
    address creator,
    bytes32 merkleRoot,
    uint256 bidAmount,
    bytes32[] calldata proof
  ) external payable override nonReentrant {
    // Verify token is in Merkle root
    bytes32 leaf = keccak256(abi.encodePacked(originContract, tokenId));
    require(MerkleProof.verify(proof, merkleRoot, leaf), "bidWithAuctionMerkleProof::Invalid Merkle proof");

    // Verify Merkle root is registered and active
    require(
      creatorAuctionMerkleRoots[creator].contains(merkleRoot),
      "bidWithAuctionMerkleProof::Merkle root not registered"
    );

    // Get config for this Merkle root
    MerkleAuctionConfig memory config = creatorRootToConfig[creator][merkleRoot];

    // Get token nonce key and verify it hasn't been used
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(creator, merkleRoot, originContract, tokenId));
    uint256 currentNonce = creatorRootNonce[creator][merkleRoot];
    require(
      tokenAuctionNonce[tokenNonceKey] < currentNonce,
      "bidWithAuctionMerkleProof::Token already used for this Merkle root"
    );

    // Verify no auction exists for this token
    require(
      tokenAuctions[originContract][tokenId].auctionType == NO_AUCTION,
      "bidWithAuctionMerkleProof::Auction already exists"
    );

    // Verify bid amount is valid
    require(bidAmount > 0, "bidWithAuctionMerkleProof::Cannot be 0");
    require(
      bidAmount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(),
      "bidWithAuctionMerkleProof::Must be less than max value"
    );
    require(bidAmount >= config.startingAmount, "bidWithAuctionMerkleProof::Cannot be lower than minimum bid");

    // Verify creator owns the token
    IERC721 erc721 = IERC721(originContract);
    require(erc721.ownerOf(tokenId) == creator, "bidWithAuctionMerkleProof::Not token owner");

    // Check marketplace approval
    marketConfig.addressMustHaveMarketplaceApprovedForNFT(creator, originContract, tokenId);

    // Transfer bid amount
    uint256 requiredAmount = bidAmount + marketConfig.marketplaceSettings.calculateMarketplaceFee(bidAmount);
    MarketUtilsV2.checkAmountAndTransfer(marketConfig, config.currency, requiredAmount);

    // Update token nonce to current creatorRootNonce
    tokenAuctionNonce[tokenNonceKey] = currentNonce;

    // Create auction
    tokenAuctions[originContract][tokenId] = Auction({
      auctionCreator: payable(creator),
      creationBlock: block.number,
      startingTime: block.timestamp,
      lengthOfAuction: config.duration,
      currencyAddress: config.currency,
      minimumBid: config.startingAmount,
      auctionType: COLDIE_AUCTION,
      splitRecipients: config.splitAddresses,
      splitRatios: config.splitRatios
    });

    // Record the bid
    auctionBids[originContract][tokenId] = Bid({
      bidder: msg.sender,
      currencyAddress: config.currency,
      amount: bidAmount,
      marketplaceFeeAtTime: marketConfig.marketplaceSettings.getMarketplaceFeePercentage()
    });

    // Transfer token from creator to this contract
    MarketUtilsV2.transferERC721(marketConfig, originContract, creator, address(this), tokenId);

    emit AuctionMerkleBid(originContract, tokenId, msg.sender, creator, merkleRoot, bidAmount, currentNonce);
  }

  /// @notice Verifies if a token is included in a Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function isTokenInRoot(
    bytes32 root,
    address origin,
    uint256 tokenId,
    bytes32[] calldata proof
  ) external pure override returns (bool) {
    bytes32 leaf = keccak256(abi.encodePacked(origin, tokenId));
    return MerkleProof.verify(proof, root, leaf);
  }

  /// @notice Gets the nonce for a specific token under a Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getTokenAuctionNonce(
    address creator,
    bytes32 root,
    address tokenContract,
    uint256 tokenId
  ) external view override returns (uint256) {
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(creator, root, tokenContract, tokenId));
    return tokenAuctionNonce[tokenNonceKey];
  }

  /// @notice Gets all Merkle roots registered by a user
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getUserAuctionMerkleRoots(address user) external view override returns (bytes32[] memory) {
    return creatorAuctionMerkleRoots[user].values();
  }

  /// @notice Gets the current nonce for a user's Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getCreatorAuctionMerkleRootNonce(address user, bytes32 root) external view override returns (uint256) {
    return creatorRootNonce[user][root];
  }

  /// @notice Gets the Merkle auction configuration for a given creator and root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getMerkleAuctionConfig(
    address creator,
    bytes32 root
  ) external view override returns (MerkleAuctionConfig memory) {
    return creatorRootToConfig[creator][root];
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Validates an auction type
  /// @param _auctionType The auction type to validate
  function _checkValidAuctionType(bytes32 _auctionType) internal pure {
    require(
      _auctionType == COLDIE_AUCTION || _auctionType == SCHEDULED_AUCTION,
      "checkValidAuctionType::Invalid auction type"
    );
  }
}
