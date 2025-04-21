// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @author SuperRare Labs
/// @title ISuperRareAuctionHouseV2
/// @notice The interface for the SuperRareAuctionHouseV2 Functions.
interface ISuperRareAuctionHouseV2 {
  /// @notice Configures an Auction for a given asset.
  /// @param _auctionType The type of auction being configured.
  /// @param _originContract Contract address of the asset being put up for auction.
  /// @param _tokenId Token Id of the asset.
  /// @param _startingAmount The reserve price or min bid of an auction.
  /// @param _currencyAddress The currency the auction is being conducted in.
  /// @param _lengthOfAuction The amount of time in seconds that the auction is configured for.
  /// @param _startTime The time the auction should start.
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
  function getCreatorAuctionMerkleRootNonce(address user, bytes32 root) external view returns (uint256);

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

  /// @notice Gets the Merkle auction configuration for a given creator and root
  /// @param creator The address of the creator
  /// @param root The Merkle root
  /// @return The MerkleAuctionConfig struct containing the auction configuration
  function getMerkleAuctionConfig(address creator, bytes32 root) external view returns (MerkleAuctionConfig memory);

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

  /// @notice Emitted when a new auction is created
  event NewAuction(
    address indexed _contractAddress,
    uint256 indexed _tokenId,
    address _auctionCreator,
    address _currencyAddress,
    uint256 _startTime,
    uint256 _startingAmount,
    uint256 _lengthOfAuction
  );

  /// @notice Emitted when an auction is cancelled
  event CancelAuction(address indexed _contractAddress, uint256 indexed _tokenId, address _auctionCreator);

  /// @notice Emitted when a bid is placed
  event AuctionBid(
    address indexed _contractAddress,
    address indexed _bidder,
    uint256 indexed _tokenId,
    address _currencyAddress,
    uint256 _amount,
    bool _firstBid,
    uint256 _marketplaceFee,
    address _previousBidder
  );

  /// @notice Emitted when an auction is settled
  event AuctionSettled(
    address indexed _contractAddress,
    uint256 indexed _tokenId,
    address _seller,
    address _bidder,
    uint256 _amount,
    uint256 _marketplaceFee
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
