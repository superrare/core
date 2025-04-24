// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/**
 * @title IRareBatchListingMarketplace
 * @notice Interface for the RareBatchListingMarketplace contract, combining standard and Merkle-based sale price functionality
 */
interface IRareBatchListingMarketplace {
  /*//////////////////////////////////////////////////////////////////////////
                                    Types
    //////////////////////////////////////////////////////////////////////////*/

  /// @notice Standard sale price configuration
  struct SalePrice {
    address payable seller;
    address currency;
    uint256 amount;
    address payable[] splitRecipients;
    uint8[] splitRatios;
  }

  /// @notice Offer configuration
  struct Offer {
    address payable buyer;
    uint256 amount;
    uint256 timestamp;
    uint8 marketplaceFee;
    bool convertible;
  }

  /// @notice Configuration for a Merkle sale price root
  struct MerkleSalePriceConfig {
    address currency;
    uint256 amount;
    address payable[] splitRecipients;
    uint8[] splitRatios;
    uint256 nonce;
  }

  /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

  event OfferPlaced(
    address indexed originContract,
    address indexed bidder,
    address indexed currencyAddress,
    uint256 amount,
    uint256 tokenId,
    bool convertible
  );

  event SetSalePrice(
    address indexed originContract,
    address indexed currencyAddress,
    address indexed target,
    uint256 amount,
    uint256 tokenId,
    address payable[] splitAddresses,
    uint8[] splitRatios
  );

  event Sold(
    address indexed originContract,
    address indexed buyer,
    address indexed seller,
    address currencyAddress,
    uint256 amount,
    uint256 tokenId
  );

  event SalePriceMerkleRootRegistered(
    address indexed creator,
    bytes32 indexed merkleRoot,
    address currency,
    uint256 amount,
    uint256 nonce
  );

  event MerkleSalePriceExecuted(
    address indexed contractAddress,
    uint256 indexed tokenId,
    address indexed buyer,
    address seller,
    bytes32 merkleRoot,
    uint256 amount,
    uint256 nonce
  );

  /*//////////////////////////////////////////////////////////////////////////
                            Merkle Sale Functions
    //////////////////////////////////////////////////////////////////////////*/

  /// @notice Register a new Merkle root for batch sale prices
  /// @param _merkleRoot The Merkle root of the token set
  /// @param _currency The currency address for the sale price (address(0) for ETH)
  /// @param _amount The sale price amount
  /// @param _splitAddresses Array of addresses to split the payment with
  /// @param _splitRatios Array of ratios for payment splits
  function registerSalePriceMerkleRoot(
    bytes32 _merkleRoot,
    address _currency,
    uint256 _amount,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external;

  /// @notice Buy a token using a Merkle proof
  /// @param _originContract The contract address of the token
  /// @param _tokenId The token ID
  /// @param _creator The creator who registered the Merkle root
  /// @param _merkleRoot The Merkle root containing this token
  /// @param _proof The Merkle proof for this token
  function buyWithMerkleProof(
    address _originContract,
    uint256 _tokenId,
    address _creator,
    bytes32 _merkleRoot,
    bytes32[] calldata _proof
  ) external payable;

  /// @notice Verify if a token is included in a Merkle root
  /// @param _root The Merkle root to check against
  /// @param _origin The token contract address
  /// @param _tokenId The token ID
  /// @param _proof The Merkle proof to verify
  function isTokenInRoot(
    bytes32 _root,
    address _origin,
    uint256 _tokenId,
    bytes32[] calldata _proof
  ) external pure returns (bool);

  /// @notice Gets the nonce for a specific token under a Merkle root
  /// @param _creator The creator who registered the root
  /// @param _root The Merkle root
  /// @param _tokenContract The token contract address
  /// @param _tokenId The token ID
  function getTokenSalePriceNonce(
    address _creator,
    bytes32 _root,
    address _tokenContract,
    uint256 _tokenId
  ) external view returns (uint256);

  /// @notice Gets all Merkle roots registered by a user
  /// @param _user The address of the user
  /// @return An array of Merkle roots
  function getUserSalePriceMerkleRoots(address _user) external view returns (bytes32[] memory);

  /// @notice Gets the current nonce for a user's Merkle root
  /// @param _user The address of the user
  /// @param _root The Merkle root
  /// @return The current nonce value
  function getCreatorSalePriceMerkleRootNonce(address _user, bytes32 _root) external view returns (uint256);

  /// @notice Gets the Merkle sale price configuration for a given creator and root
  /// @param _creator The address of the creator
  /// @param _root The Merkle root
  /// @return The MerkleSalePriceConfig struct containing the sale price configuration
  function getMerkleSalePriceConfig(
    address _creator,
    bytes32 _root
  ) external view returns (MerkleSalePriceConfig memory);
}
