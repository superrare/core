// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @author SuperRare Labs
/// @title IRareBatchAuctionHouse
/// @notice The interface for the RareBatchAuctionHouse Functions.
interface IRareBatchAuctionHouse {
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

  /// @notice Gets the current bid details for a specific token
  /// @param _originContract Contract address of the asset
  /// @param _tokenId Token Id of the asset
  /// @return bidder The address of the current highest bidder
  /// @return currencyAddress The currency address of the bid
  /// @return amount The amount of the current highest bid
  /// @return marketplaceFeeAtTime The marketplace fee percentage at the time of the bid
  function getCurrentBid(
    address _originContract,
    uint256 _tokenId
  ) external view returns (address bidder, address currencyAddress, uint256 amount, uint256 marketplaceFeeAtTime);

  // Merkle Auction Functions

  /// @notice Registers a new Merkle root for auction configuration
  /// @param _merkleRoot The root hash of the Merkle tree containing token IDs
  /// @param _currency The currency address for the auction
  /// @param _startingAmount The minimum bid amount
  /// @param _duration The length of the auction in seconds
  /// @param _splitAddresses The addresses to split the proceeds with
  /// @param _splitRatios The ratios for each split address
  function registerAuctionMerkleRoot(
    bytes32 _merkleRoot,
    address _currency,
    uint256 _startingAmount,
    uint256 _duration,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external;

  /// @notice Cancels a previously registered Merkle root
  /// @param _root The Merkle root to cancel
  function cancelAuctionMerkleRoot(bytes32 _root) external;

  /// @notice Places a bid using a Merkle proof to verify token inclusion
  /// @param _originContract The contract address of the token
  /// @param _tokenId The ID of the token being bid on
  /// @param _creator The creator of the auction
  /// @param _merkleRoot The root hash of the Merkle tree
  /// @param _bidAmount The amount of the bid
  /// @param _proof The Merkle proof verifying token inclusion
  function bidWithAuctionMerkleProof(
    address _originContract,
    uint256 _tokenId,
    address _creator,
    bytes32 _merkleRoot,
    uint256 _bidAmount,
    bytes32[] calldata _proof
  ) external payable;

  /// @notice Gets all Merkle roots registered by a user
  /// @param _user The address of the user
  /// @return An array of Merkle roots
  function getUserAuctionMerkleRoots(address _user) external view returns (bytes32[] memory);

  /// @notice Gets the current nonce for a user's Merkle root
  /// @param _user The address of the user
  /// @param _root The Merkle root
  /// @return The current nonce value
  function getCreatorAuctionMerkleRootNonce(address _user, bytes32 _root) external view returns (uint256);

  /// @notice Verifies if a token is included in a Merkle root
  /// @param _root The Merkle root to check against
  /// @param _origin The contract address of the token
  /// @param _tokenId The ID of the token
  /// @param _proof The Merkle proof for verification
  /// @return True if the token is included in the root, false otherwise
  function isTokenInRoot(
    bytes32 _root,
    address _origin,
    uint256 _tokenId,
    bytes32[] calldata _proof
  ) external pure returns (bool);

  /// @notice Gets the Merkle auction configuration for a given creator and root
  /// @param _creator The address of the creator
  /// @param _root The Merkle root
  /// @return The MerkleAuctionConfig struct containing the auction configuration
  function getMerkleAuctionConfig(address _creator, bytes32 _root) external view returns (MerkleAuctionConfig memory);

  /// @notice Gets the nonce for a specific token under a Merkle root
  /// @param _creator The creator of the auction
  /// @param _root The Merkle root
  /// @param _tokenContract The token contract address
  /// @param _tokenId The token ID
  /// @return The current nonce for this token
  function getTokenAuctionNonce(
    address _creator,
    bytes32 _root,
    address _tokenContract,
    uint256 _tokenId
  ) external view returns (uint256);

  // Structs

  /// @notice Struct for storing auction configuration information
  struct Auction {
    address payable auctionCreator;
    uint256 creationBlock;
    uint256 startingTime;
    uint256 lengthOfAuction;
    address currencyAddress;
    uint256 minimumBid;
    bytes32 auctionType;
    address payable[] splitRecipients;
    uint8[] splitRatios;
  }

  /// @notice Struct for storing bid information
  struct Bid {
    address bidder;
    address currencyAddress;
    uint256 amount;
    uint256 marketplaceFeeAtTime;
  }

  /// @notice Struct for storing Merkle auction configuration
  struct MerkleAuctionConfig {
    address currency;
    uint256 startingAmount;
    uint256 duration;
    address payable[] splitAddresses;
    uint8[] splitRatios;
    uint256 nonce;
  }

  // Events

  /// @notice Emitted when an auction is cancelled
  event CancelAuction(address indexed contractAddress, uint256 indexed tokenId, address auctionCreator);

  /// @notice Emitted when a bid is placed
  event AuctionBid(
    address indexed contractAddress,
    address indexed bidder,
    uint256 indexed tokenId,
    address currencyAddress,
    uint256 amount,
    uint256 marketplaceFee,
    address previousBidder
  );

  /// @notice Emitted when an auction is settled
  event AuctionSettled(
    address indexed contractAddress,
    uint256 indexed tokenId,
    address seller,
    address bidder,
    uint256 amount,
    address currencyAddress,
    uint256 marketplaceFee
  );

  /// @notice Emitted when a Merkle auction root is registered
  event AuctionMerkleRootRegistered(
    address indexed creator,
    bytes32 indexed merkleRoot,
    address currencyAddress,
    uint256 startingAmount,
    uint256 duration,
    uint256 nonce
  );

  /// @notice Emitted when a Merkle auction root is cancelled
  event AuctionMerkleRootCancelled(address indexed creator, bytes32 indexed merkleRoot);

  /// @notice Emitted when a bid with Merkle proof is placed
  event AuctionMerkleBid(
    address indexed contractAddress,
    uint256 indexed tokenId,
    address indexed bidder,
    address creator,
    bytes32 merkleRoot,
    uint256 amount,
    uint256 nonce
  );
}
