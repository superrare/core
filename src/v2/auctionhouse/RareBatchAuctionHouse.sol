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
import {IRareBatchAuctionHouse} from "./IRareBatchAuctionHouse.sol";

/// @author SuperRare Labs
/// @title RareBatchAuctionHouse
/// @notice The logic for all functions related to the RareBatchAuctionHouse.
/// @dev This contract consolidates standard auction functionality from the SuperRare Bazaar
/// with the existing Merkle auction features, ensuring full adoption of MarketUtilsV2.
contract RareBatchAuctionHouse is IRareBatchAuctionHouse, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using EnumerableSet for EnumerableSet.Bytes32Set;
  using MarketConfigV2 for MarketConfigV2.Config;
  using MarketUtilsV2 for MarketConfigV2.Config;

  // Constants
  bytes32 public constant NO_AUCTION = bytes32(0);
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

  /// @notice Places a bid on a valid auction.
  /// @inheritdoc IRareBatchAuctionHouse
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
      marketConfig.marketplaceSettings.getMarketplaceFeePercentage(),
      previousBidder
    );
  }

  /// @notice Settles an auction that has ended.
  /// @inheritdoc IRareBatchAuctionHouse
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
      currentBid.currencyAddress,
      currentBid.marketplaceFeeAtTime
    );
  }

  /// @notice Grabs the current auction details for a token.
  /// @inheritdoc IRareBatchAuctionHouse
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
  /// @inheritdoc IRareBatchAuctionHouse
  function registerAuctionMerkleRoot(
    bytes32 _merkleRoot,
    address _currency,
    uint256 _startingAmount,
    uint256 _duration,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external override {
    // Check if currency is approved
    marketConfig.checkIfCurrencyIsApproved(_currency);

    // Validate split configuration
    MarketUtilsV2.checkSplits(_splitAddresses, _splitRatios);

    // Verify duration is not too long
    require(_duration <= maxAuctionLength, "registerAuctionMerkleRoot::Duration too long");

    // Verify starting amount is valid
    require(
      _startingAmount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(),
      "registerAuctionMerkleRoot::Starting amount exceeds maximum value"
    );

    // Add root to user's set of roots
    creatorAuctionMerkleRoots[msg.sender].add(_merkleRoot);

    // Calculate new nonce
    uint256 newNonce = creatorRootNonce[msg.sender][_merkleRoot] + 1;
    creatorRootNonce[msg.sender][_merkleRoot] = newNonce;

    creatorRootToConfig[msg.sender][_merkleRoot] = MerkleAuctionConfig({
      currency: _currency,
      startingAmount: _startingAmount,
      duration: _duration,
      splitAddresses: _splitAddresses,
      splitRatios: _splitRatios,
      nonce: newNonce
    });

    emit AuctionMerkleRootRegistered(msg.sender, _merkleRoot, _currency, _startingAmount, _duration, newNonce);
  }

  /// @notice Cancels a previously registered Merkle root
  /// @inheritdoc IRareBatchAuctionHouse
  function cancelAuctionMerkleRoot(bytes32 _root) external override {
    // Check if caller owns the root
    require(creatorAuctionMerkleRoots[msg.sender].contains(_root), "cancelAuctionMerkleRoot::Not root owner");

    // Remove root from user's set
    creatorAuctionMerkleRoots[msg.sender].remove(_root);

    // Clean up config data (note: we keep the nonce for security)
    delete creatorRootToConfig[msg.sender][_root];

    // Emit event
    emit AuctionMerkleRootCancelled(msg.sender, _root);
  }

  /// @notice Places a bid using a Merkle proof to verify token inclusion
  /// @inheritdoc IRareBatchAuctionHouse
  function bidWithAuctionMerkleProof(
    address _originContract,
    uint256 _tokenId,
    address _creator,
    bytes32 _merkleRoot,
    uint256 _bidAmount,
    bytes32[] calldata _proof
  ) external payable override nonReentrant {
    // Verify token is in Merkle root
    bytes32 leaf = keccak256(abi.encodePacked(_originContract, _tokenId));
    require(MerkleProof.verify(_proof, _merkleRoot, leaf), "bidWithAuctionMerkleProof::Invalid Merkle proof");

    // Verify Merkle root is registered and active
    require(
      creatorAuctionMerkleRoots[_creator].contains(_merkleRoot),
      "bidWithAuctionMerkleProof::Merkle root not registered"
    );

    // Get config for this Merkle root
    MerkleAuctionConfig memory config = creatorRootToConfig[_creator][_merkleRoot];

    // Get token nonce key and verify it hasn't been used
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(_creator, _merkleRoot, _originContract, _tokenId));
    uint256 currentNonce = creatorRootNonce[_creator][_merkleRoot];
    require(
      tokenAuctionNonce[tokenNonceKey] < currentNonce,
      "bidWithAuctionMerkleProof::Token already used for this Merkle root"
    );

    // Verify no auction exists for this token
    require(
      tokenAuctions[_originContract][_tokenId].auctionType == NO_AUCTION,
      "bidWithAuctionMerkleProof::Auction already exists"
    );

    // Verify bid amount is valid
    require(_bidAmount > 0, "bidWithAuctionMerkleProof::Cannot be 0");
    require(
      _bidAmount <= marketConfig.marketplaceSettings.getMarketplaceMaxValue(),
      "bidWithAuctionMerkleProof::Must be less than max value"
    );
    require(_bidAmount >= config.startingAmount, "bidWithAuctionMerkleProof::Cannot be lower than minimum bid");

    // Verify creator owns the token
    IERC721 erc721 = IERC721(_originContract);
    require(erc721.ownerOf(_tokenId) == _creator, "bidWithAuctionMerkleProof::Not token owner");

    // Check marketplace approval
    marketConfig.addressMustHaveMarketplaceApprovedForNFT(_creator, _originContract, _tokenId);

    // Transfer bid amount
    uint256 requiredAmount = _bidAmount + marketConfig.marketplaceSettings.calculateMarketplaceFee(_bidAmount);
    MarketUtilsV2.checkAmountAndTransfer(marketConfig, config.currency, requiredAmount);

    // Update token nonce to current creatorRootNonce
    tokenAuctionNonce[tokenNonceKey] = currentNonce;

    // Create auction
    tokenAuctions[_originContract][_tokenId] = Auction({
      auctionCreator: payable(_creator),
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
    auctionBids[_originContract][_tokenId] = Bid({
      bidder: msg.sender,
      currencyAddress: config.currency,
      amount: _bidAmount,
      marketplaceFeeAtTime: marketConfig.marketplaceSettings.getMarketplaceFeePercentage()
    });

    // Transfer token from creator to this contract
    MarketUtilsV2.transferERC721(marketConfig, _originContract, _creator, address(this), _tokenId);

    emit AuctionMerkleBid(_originContract, _tokenId, msg.sender, _creator, _merkleRoot, _bidAmount, currentNonce);
  }

  /// @notice Verifies if a token is included in a Merkle root
  /// @inheritdoc IRareBatchAuctionHouse
  function isTokenInRoot(
    bytes32 _root,
    address _origin,
    uint256 _tokenId,
    bytes32[] calldata _proof
  ) external pure override returns (bool) {
    bytes32 leaf = keccak256(abi.encodePacked(_origin, _tokenId));
    return MerkleProof.verify(_proof, _root, leaf);
  }

  /// @notice Gets the nonce for a specific token under a Merkle root
  /// @inheritdoc IRareBatchAuctionHouse
  function getTokenAuctionNonce(
    address _creator,
    bytes32 _root,
    address _tokenContract,
    uint256 _tokenId
  ) external view override returns (uint256) {
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(_creator, _root, _tokenContract, _tokenId));
    return tokenAuctionNonce[tokenNonceKey];
  }

  /// @notice Gets all Merkle roots registered by a user
  /// @inheritdoc IRareBatchAuctionHouse
  function getUserAuctionMerkleRoots(address _user) external view override returns (bytes32[] memory) {
    return creatorAuctionMerkleRoots[_user].values();
  }

  /// @notice Gets the current nonce for a user's Merkle root
  /// @inheritdoc IRareBatchAuctionHouse
  function getCreatorAuctionMerkleRootNonce(address _user, bytes32 _root) external view override returns (uint256) {
    return creatorRootNonce[_user][_root];
  }

  /// @notice Gets the Merkle auction configuration for a given creator and root
  /// @inheritdoc IRareBatchAuctionHouse
  function getMerkleAuctionConfig(
    address _creator,
    bytes32 _root
  ) external view override returns (MerkleAuctionConfig memory) {
    return creatorRootToConfig[_creator][_root];
  }

  /// @inheritdoc IRareBatchAuctionHouse
  function getCurrentBid(
    address _originContract,
    uint256 _tokenId
  )
    external
    view
    override
    returns (address bidder, address currencyAddress, uint256 amount, uint256 marketplaceFeeAtTime)
  {
    Bid memory bid = auctionBids[_originContract][_tokenId];
    return (bid.bidder, bid.currencyAddress, bid.amount, bid.marketplaceFeeAtTime);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @dev Validates an auction type
  /// @param _auctionType The auction type to validate
  function _checkValidAuctionType(bytes32 _auctionType) internal pure {
    require(_auctionType == COLDIE_AUCTION, "checkValidAuctionType::Invalid auction type");
  }
}
