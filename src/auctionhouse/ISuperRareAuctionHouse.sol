// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SuperRareBazaarStorage} from "../bazaar/SuperRareBazaarStorage.sol";

/// @author koloz
/// @title ISuperRareAuctionHouse
/// @notice The interface for the SuperRareAuctionHouse Functions.
interface ISuperRareAuctionHouse {
  /// @notice Configures an Auction for a given asset.
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
  ) external;

  /// @notice Converts an offer into a coldie auction.
  /// @param _originContract Contract address of the asset.
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
  ) external;

  /// @notice Cancels a configured Auction that has not started.
  /// @param _originContract Contract address of the asset pending auction.
  /// @param _tokenId Token Id of the asset.
  function cancelAuction(address _originContract, uint256 _tokenId) external;

  /// @notice Places a bid on a valid auction.
  /// @param _originContract Contract address of asset being bid on.
  /// @param _tokenId Token Id of the asset.
  /// @param _currencyAddress Address of currency being used to bid.
  /// @param _amount Amount of the currency being used for the bid.
  function bid(address _originContract, uint256 _tokenId, address _currencyAddress, uint256 _amount) external payable;

  /// @notice Settles an auction that has ended.
  /// @param _originContract Contract address of asset.
  /// @param _tokenId Token Id of the asset.
  function settleAuction(address _originContract, uint256 _tokenId) external;

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
    returns (address, uint256, uint256, uint256, address, uint256, bytes32, address payable[] memory, uint8[] memory);

  // Merkle Auction Functions

  /// @notice Registers a new Merkle root for auction configuration
  /// @param merkleRoot The root hash of the Merkle tree containing token IDs
  /// @param currency The currency address for the auction
  /// @param startingAmount The minimum bid amount
  /// @param duration The length of the auction in seconds
  /// @param splitAddresses The addresses to split the proceeds with
  /// @param splitRatios The ratios for each split address
  function registerAuctionMerkleRoot(
    bytes32 merkleRoot,
    address currency,
    uint256 startingAmount,
    uint256 duration,
    address payable[] calldata splitAddresses,
    uint8[] calldata splitRatios
  ) external;

  /// @notice Cancels a previously registered Merkle root
  /// @param root The Merkle root to cancel
  function cancelAuctionMerkleRoot(bytes32 root) external;

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
  ) external payable;

  /// @notice Gets all Merkle roots registered by a user
  /// @param user The address of the user
  /// @return An array of Merkle roots
  function getUserAuctionMerkleRoots(address user) external view returns (bytes32[] memory);

  /// @notice Gets the current nonce for a user's Merkle root
  /// @param user The address of the user
  /// @param root The Merkle root
  /// @return The current nonce value
  function getCurrentAuctionMerkleRootNonce(address user, bytes32 root) external view returns (uint256);

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
  ) external pure returns (bool);

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
  ) external view returns (uint256);
}
