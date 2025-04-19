// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {SuperRareBazaarBase} from "../bazaar/SuperRareBazaarBase.sol";
import {SuperRareBazaarStorage} from "../bazaar/SuperRareBazaarStorage.sol";
import {ISuperRareAuctionHouse} from "./ISuperRareAuctionHouse.sol";
import {MerkleProof} from "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";

/// @author koloz
/// @title SuperRareAuctionHouse
/// @notice The logic for all functions related to the SuperRareAuctionHouse.
contract SuperRareAuctionHouse is
  ISuperRareAuctionHouse,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable,
  SuperRareBazaarBase
{
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.Bytes32Set;

  /// @notice Configures an Auction for a given asset.
  /// @dev If auction type is coldie (reserve) then _startingAmount cant be 0.
  /// @dev _currencyAddress equal to the zero address denotes eth.
  /// @dev All time related params are unix epoch timestamps.
  /// @param _auctionType The type of auction being configured.
  /// @param _originContract Contract address of the asset being put up for auction.
  /// @param _tokenId Token Id of the asset.
  /// @param _startingAmount The reserve price or min bid of an auction.
  /// @param _currencyAddress The currency the auction is being conducted in.
  /// @param _lengthOfAuction The amount of time in seconds that the auction is configured for.
  /// @param _splitAddresses Addresses to split the sellers commission with.
  /// @param _splitRatios The ratio for the split corresponding to each of the addresses being split with.
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
    _checkIfCurrencyIsApproved(_currencyAddress);
    _senderMustBeTokenOwner(_originContract, _tokenId);
    _ownerMustHaveMarketplaceApprovedForNFT(_originContract, _tokenId);
    _checkSplits(_splitAddresses, _splitRatios);
    _checkValidAuctionType(_auctionType);

    {
      require(_lengthOfAuction <= maxAuctionLength, "configureAuction::Auction too long.");

      Auction memory auction = tokenAuctions[_originContract][_tokenId];

      Bid memory staleBid = auctionBids[_originContract][_tokenId];

      require(staleBid.bidder == address(0), "configureAuction::bid shouldnt exist");

      require(
        auction.auctionType == NO_AUCTION || (auction.auctionCreator != msg.sender),
        "configureAuction::Cannot have a current auction"
      );

      require(_lengthOfAuction > 0, "configureAuction::Length must be > 0");

      if (_auctionType == COLDIE_AUCTION) {
        require(_startingAmount > 0, "configureAuction::Coldie starting price must be > 0");
      } else if (_auctionType == SCHEDULED_AUCTION) {
        require(_startTime > block.timestamp, "configureAuction::Scheduled auction cannot start in past.");
      }

      require(
        _startingAmount <= marketplaceSettings.getMarketplaceMaxValue(),
        "configureAuction::Cannot set starting price higher than max value."
      );
    }

    tokenAuctions[_originContract][_tokenId] = Auction(
      payable(msg.sender),
      block.number,
      _auctionType == COLDIE_AUCTION ? 0 : _startTime,
      _lengthOfAuction,
      _currencyAddress,
      _startingAmount,
      _auctionType,
      _splitAddresses,
      _splitRatios
    );

    if (_auctionType == SCHEDULED_AUCTION) {
      IERC721 erc721 = IERC721(_originContract);
      erc721.transferFrom(msg.sender, address(this), _tokenId);
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

  /// @notice Converts an offer into a coldie auction.
  /// @param _originContract Contract address of the asset.
  /// @dev Covers use of any currency (0 address is eth).
  /// @dev Only covers converting an offer to a coldie auction.
  /// @dev Cant convert offer if an auction currently exists.
  /// @param _tokenId Token Id of the asset.
  /// @param _currencyAddress Address of the currency being converted.
  /// @param _amount Amount being converted into an auction.
  /// @param _lengthOfAuction Number of seconds the auction will last.
  /// @param _splitAddresses Addresses that the sellers take in will be split amongst.
  /// @param _splitRatios Ratios that the take in will be split by.
  function convertOfferToAuction(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    uint256 _lengthOfAuction,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external override {
    require(false, "convertOfferToAuction::Deprecated");
    _senderMustBeTokenOwner(_originContract, _tokenId);
    _ownerMustHaveMarketplaceApprovedForNFT(_originContract, _tokenId);
    _checkSplits(_splitAddresses, _splitRatios);

    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    require(
      auction.auctionType == NO_AUCTION || auction.auctionCreator != msg.sender,
      "convertOfferToAuction::Cannot have a current auction."
    );

    require(
      auction.startingTime == 0 || block.timestamp < auction.startingTime,
      "convertOfferToAuction::Auction must not have started."
    );

    require(_lengthOfAuction <= maxAuctionLength, "convertOfferToAuction::Auction too long.");

    Offer memory currOffer = tokenCurrentOffers[_originContract][_tokenId][_currencyAddress];

    require(currOffer.buyer != msg.sender, "convert::own offer");

    require(currOffer.convertible, "convertOfferToAuction::Offer is not convertible");

    require(currOffer.amount == _amount, "convertOfferToAuction::Converting offer with different amount.");

    tokenAuctions[_originContract][_tokenId] = Auction(
      payable(msg.sender),
      block.number,
      block.timestamp,
      _lengthOfAuction,
      _currencyAddress,
      currOffer.amount,
      COLDIE_AUCTION,
      _splitAddresses,
      _splitRatios
    );

    delete tokenCurrentOffers[_originContract][_tokenId][_currencyAddress];

    auctionBids[_originContract][_tokenId] = Bid(
      currOffer.buyer,
      _currencyAddress,
      _amount,
      marketplaceSettings.getMarketplaceFeePercentage()
    );

    IERC721 erc721 = IERC721(_originContract);
    erc721.transferFrom(msg.sender, address(this), _tokenId);

    emit NewAuction(
      _originContract,
      _tokenId,
      msg.sender,
      _currencyAddress,
      block.timestamp,
      _amount,
      _lengthOfAuction
    );

    emit AuctionBid(_originContract, currOffer.buyer, _tokenId, _currencyAddress, _amount, true, 0, address(0));
  }

  /// @notice Cancels a configured Auction that has not started.
  /// @dev Requires the person sending the message to be the auction creator or token owner.
  /// @param _originContract Contract address of the asset pending auction.
  /// @param _tokenId Token Id of the asset.
  function cancelAuction(address _originContract, uint256 _tokenId) external override {
    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    IERC721 erc721 = IERC721(_originContract);

    require(auction.auctionType != NO_AUCTION, "cancelAuction::Must have an auction configured.");

    require(
      auction.startingTime == 0 || block.timestamp < auction.startingTime,
      "cancelAuction::Auction must not have started."
    );

    require(
      auction.auctionCreator == msg.sender || erc721.ownerOf(_tokenId) == msg.sender,
      "cancelAuction::Must be creator or owner."
    );

    delete tokenAuctions[_originContract][_tokenId];

    if (erc721.ownerOf(_tokenId) == address(this)) {
      erc721.transferFrom(address(this), msg.sender, _tokenId);
    }

    require(erc721.ownerOf(_tokenId) == msg.sender, "sending failed");

    emit CancelAuction(_originContract, _tokenId, auction.auctionCreator);
  }

  /// @notice Places a bid on a valid auction.
  /// @dev Only the configured currency can be used (Zero address for eth)
  /// @param _originContract Contract address of asset being bid on.
  /// @param _tokenId Token Id of the asset.
  /// @param _currencyAddress Address of currency being used to bid.
  /// @param _amount Amount of the currency being used for the bid.
  function bid(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount
  ) external payable override nonReentrant {
    uint256 requiredAmount = _amount + marketplaceSettings.calculateMarketplaceFee(_amount);

    _senderMustHaveMarketplaceApproved(_currencyAddress, requiredAmount);

    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    require(auction.auctionType != NO_AUCTION, "bid::Must have a current auction.");

    require(auction.auctionCreator != msg.sender, "bid::Cannot bid on your own auction.");

    require(block.timestamp >= auction.startingTime, "bid::Auction not active.");

    require(_currencyAddress == auction.currencyAddress, "bid::Currency must be in configured denomination");

    require(_amount > 0, "bid::Cannot be 0");

    require(_amount <= marketplaceSettings.getMarketplaceMaxValue(), "bid::Must be less than max value.");

    require(_amount >= auction.minimumBid, "bid::Cannot be lower than minimum bid.");

    require(
      auction.startingTime == 0 || block.timestamp < auction.startingTime + auction.lengthOfAuction,
      "bid::Must be active."
    );

    Bid memory currBid = auctionBids[_originContract][_tokenId];

    require(
      _amount >= currBid.amount + ((currBid.amount * minimumBidIncreasePercentage) / 100),
      "bid::Must be higher than prev bid + min increase."
    );

    IERC721 erc721 = IERC721(_originContract);
    address tokenOwner = erc721.ownerOf(_tokenId);

    require(auction.auctionCreator == tokenOwner || tokenOwner == address(this), "bid::Auction creator must be owner.");

    if (auction.auctionCreator == tokenOwner) {
      _ownerMustHaveMarketplaceApprovedForNFT(_originContract, _tokenId);
    }

    _checkAmountAndTransfer(_currencyAddress, requiredAmount);

    _refund(_currencyAddress, currBid.amount, currBid.marketplaceFee, currBid.bidder);

    auctionBids[_originContract][_tokenId] = Bid(
      payable(msg.sender),
      _currencyAddress,
      _amount,
      marketplaceSettings.getMarketplaceFeePercentage()
    );

    bool startedAuction = false;
    uint256 newAuctionLength = 0;

    if (auction.startingTime == 0) {
      tokenAuctions[_originContract][_tokenId].startingTime = block.timestamp;

      erc721.transferFrom(auction.auctionCreator, address(this), _tokenId);

      startedAuction = true;
    } else if (auction.startingTime + auction.lengthOfAuction - block.timestamp < auctionLengthExtension) {
      newAuctionLength = block.timestamp + auctionLengthExtension - auction.startingTime;

      tokenAuctions[_originContract][_tokenId].lengthOfAuction = newAuctionLength;
    }

    emit AuctionBid(
      _originContract,
      msg.sender,
      _tokenId,
      _currencyAddress,
      _amount,
      startedAuction,
      newAuctionLength,
      currBid.bidder
    );
  }

  /// @notice Settles an auction that has ended.
  /// @dev Anyone is able to settle an auction since non-input params are used.
  /// @param _originContract Contract address of asset.
  /// @param _tokenId Token Id of the asset.
  function settleAuction(address _originContract, uint256 _tokenId) external override {
    Auction memory auction = tokenAuctions[_originContract][_tokenId];

    require(
      auction.auctionType != NO_AUCTION && auction.startingTime != 0,
      "settleAuction::Must have a current valid auction."
    );

    require(
      block.timestamp >= auction.startingTime + auction.lengthOfAuction,
      "settleAuction::Can only settle ended auctions."
    );

    Bid memory currBid = auctionBids[_originContract][_tokenId];

    delete tokenAuctions[_originContract][_tokenId];
    delete auctionBids[_originContract][_tokenId];

    IERC721 erc721 = IERC721(_originContract);

    if (currBid.bidder == address(0)) {
      erc721.transferFrom(address(this), auction.auctionCreator, _tokenId);
      require(
        erc721.ownerOf(_tokenId) == auction.auctionCreator,
        "settleAuction::Failed to return token to auction creator"
      );
    } else {
      erc721.transferFrom(address(this), currBid.bidder, _tokenId);

      _payout(
        _originContract,
        _tokenId,
        currBid.currencyAddress,
        currBid.amount,
        auction.auctionCreator,
        auction.splitRecipients,
        auction.splitRatios
      );

      marketplaceSettings.markERC721Token(_originContract, _tokenId, true);
      require(erc721.ownerOf(_tokenId) == currBid.bidder, "settleAuction::Failed to transfer to auction winner");
    }

    emit AuctionSettled(
      _originContract,
      currBid.bidder,
      auction.auctionCreator,
      _tokenId,
      auction.currencyAddress,
      currBid.amount
    );
  }

  /// @notice Grabs the current auction details for a token.
  /// @param _originContract Contract address of asset.
  /// @param _tokenId Token Id of the asset.
  /** @return Auction Struct: creatorAddress, creationTime, startingTime, lengthOfAuction,
                currencyAddress, minimumBid, auctionType, splitRecipients array, and splitRatios array.
    */
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

  function _checkValidAuctionType(bytes32 _auctionType) internal pure {
    if (_auctionType != COLDIE_AUCTION && _auctionType != SCHEDULED_AUCTION) {
      revert("Invalid Auction Type");
    }
  }

  /// @notice Registers a new Merkle root for auction configuration
  /// @param merkleRoot The root hash of the Merkle tree containing token IDs
  /// @param currency The currency address for the auction
  /// @param startingAmount The starting amount for the auction
  /// @param duration The duration of the auction
  /// @param splitAddresses Addresses to split the sellers commission with
  /// @param splitRatios Ratios for splitting the commission
  function registerAuctionMerkleRoot(
    bytes32 merkleRoot,
    address currency,
    uint256 startingAmount,
    uint256 duration,
    address payable[] calldata splitAddresses,
    uint8[] calldata splitRatios
  ) external override {
    // Check if currency is approved
    _checkIfCurrencyIsApproved(currency);

    // Add root to user's set of roots
    _userAuctionMerkleRoots[msg.sender].add(merkleRoot);

    // Get current config if it exists
    MerkleAuctionConfig memory currentConfig = auctionMerkleConfigs[msg.sender][merkleRoot];

    // Calculate new nonce
    uint256 newNonce = currentConfig.nonce > 0 ? currentConfig.nonce + 1 : 1;

    // Create and store new config
    auctionMerkleConfigs[msg.sender][merkleRoot] = MerkleAuctionConfig({
      currency: currency,
      startingAmount: startingAmount,
      duration: duration,
      splitAddresses: splitAddresses,
      splitRatios: splitRatios,
      nonce: newNonce
    });

    emit NewAuctionMerkleRoot(msg.sender, merkleRoot, newNonce);
  }

  /// @notice Cancels a previously registered Merkle root
  /// @param root The Merkle root to cancel
  function cancelAuctionMerkleRoot(bytes32 root) external override {
    // Check if caller owns the root
    require(_userAuctionMerkleRoots[msg.sender].contains(root), "Not root owner");

    // Remove root from user's set
    _userAuctionMerkleRoots[msg.sender].remove(root);

    // Clean up config data
    delete auctionMerkleConfigs[msg.sender][root];

    // Emit event
    emit AuctionMerkleRootCancelled(msg.sender, root);
  }

  /// @notice Places a bid using a Merkle proof to verify token inclusion
  /// @param originContract The contract address of the token
  /// @param tokenId The ID of the token being bid on
  /// @param creator The creator of the auction
  /// @param merkleRoot The root hash of the Merkle tree
  /// @param bidAmount The amount of the bid
  /// @param proof The Merkle proof verifying token inclusion
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
      _userAuctionMerkleRoots[creator].contains(merkleRoot),
      "bidWithAuctionMerkleProof::Merkle root not registered"
    );

    // Get config for this Merkle root
    MerkleAuctionConfig memory config = auctionMerkleConfigs[creator][merkleRoot];

    // Get token nonce key and verify it hasn't been used
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(creator, merkleRoot, originContract, tokenId));
    require(
      tokenAuctionNonce[tokenNonceKey] < config.nonce,
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
      bidAmount <= marketplaceSettings.getMarketplaceMaxValue(),
      "bidWithAuctionMerkleProof::Must be less than max value"
    );
    require(bidAmount >= config.startingAmount, "bidWithAuctionMerkleProof::Cannot be lower than minimum bid");

    // Verify creator owns the token
    require(IERC721(originContract).ownerOf(tokenId) == creator, "bidWithAuctionMerkleProof::Not token owner");

    // Transfer bid amount
    uint256 requiredAmount = bidAmount + marketplaceSettings.calculateMarketplaceFee(bidAmount);
    _checkAmountAndTransfer(config.currency, requiredAmount);

    // Update token nonce to current config nonce + 1
    tokenAuctionNonce[tokenNonceKey] = tokenAuctionNonce[tokenNonceKey] + 1;

    // Create auction
    tokenAuctions[originContract][tokenId] = Auction(
      payable(creator),
      block.number,
      block.timestamp,
      config.duration,
      config.currency,
      config.startingAmount,
      COLDIE_AUCTION,
      config.splitAddresses,
      config.splitRatios
    );

    // Record the bid
    auctionBids[originContract][tokenId] = Bid(
      payable(msg.sender),
      config.currency,
      bidAmount,
      marketplaceSettings.getMarketplaceFeePercentage()
    );

    // Transfer token from creator to auction house
    IERC721(originContract).transferFrom(creator, address(this), tokenId);

    emit AuctionMerkleBid(
      originContract,
      msg.sender,
      tokenId,
      config.currency,
      bidAmount,
      merkleRoot,
      true, // startedAuction
      0, // newAuctionLength
      address(0) // previousBidder
    );
  }

  /// @notice Gets all Merkle roots registered by a user
  /// @param user The address of the user
  /// @return An array of Merkle roots
  function getUserAuctionMerkleRoots(address user) external view override returns (bytes32[] memory) {
    return _userAuctionMerkleRoots[user].values();
  }

  /// @notice Gets the current nonce for a user's Merkle root
  /// @param user The address of the user
  /// @param root The Merkle root
  /// @return The current nonce value
  function getCurrentAuctionMerkleRootNonce(address user, bytes32 root) external view override returns (uint256) {
    return auctionMerkleConfigs[user][root].nonce;
  }

  /// @notice Verifies if a token is included in a Merkle root
  /// @param root The Merkle root to check against
  /// @param origin The contract address of the token
  /// @param tokenId The ID of the token
  /// @param proof The Merkle proof for verification
  /// @return True if the token is included in the root, false otherwise
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
  /// @param creator The creator of the auction
  /// @param root The Merkle root
  /// @param tokenContract The token contract address
  /// @param tokenId The token ID
  /// @return The current nonce for this token
  function getTokenAuctionNonce(
    address creator,
    bytes32 root,
    address tokenContract,
    uint256 tokenId
  ) external view returns (uint256) {
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(creator, root, tokenContract, tokenId));
    return tokenAuctionNonce[tokenNonceKey];
  }
}
