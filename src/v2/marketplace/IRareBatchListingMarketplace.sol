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

  /// @notice Configuration for a Merkle sale price root
  struct MerkleSalePriceConfig {
    address currency;
    uint256 amount;
    address payable[] splitRecipients;
    uint8[] splitRatios;
    uint256 nonce;
  }

  /// @notice Configuration for allowlist Merkle root
  struct AllowListConfig {
    bytes32 root;
    uint256 endTimestamp;
  }

  /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

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

  event AllowListConfigSet(
    address indexed creator,
    bytes32 indexed merkleRoot,
    bytes32 indexed allowListRoot,
    uint256 endTimestamp
  );

  event SalePriceMerkleRootCancelled(address indexed creator, bytes32 indexed merkleRoot);

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

  /// @notice Cancels a previously registered sale price Merkle root
  /// @param _merkleRoot The Merkle root to cancel
  function cancelSalePriceMerkleRoot(bytes32 _merkleRoot) external;

  /// @notice Set allowlist configuration for a sale price Merkle root
  /// @param _merkleRoot The sale price Merkle root to set allowlist for
  /// @param _allowListRoot The Merkle root of allowed addresses
  /// @param _endTimestamp The timestamp after which the allowlist expires
  function setAllowListConfig(bytes32 _merkleRoot, bytes32 _allowListRoot, uint256 _endTimestamp) external;

  /// @notice Buy a token using a Merkle proof
  /// @param _originContract The contract address of the token
  /// @param _tokenId The token ID
  /// @param _creator The creator who registered the Merkle root
  /// @param _merkleRoot The Merkle root containing this token
  /// @param _proof The Merkle proof for this token
  /// @param _allowListProof The Merkle proof for the allowlist (empty if no allowlist)
  function buyWithMerkleProof(
    address _originContract,
    uint256 _tokenId,
    address _creator,
    bytes32 _merkleRoot,
    bytes32[] calldata _proof,
    bytes32[] calldata _allowListProof
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

  /// @notice Gets the allowlist configuration for a given creator and sale price root
  /// @param _creator The address of the creator
  /// @param _merkleRoot The sale price Merkle root
  /// @return The AllowListConfig struct containing the allowlist configuration
  function getAllowListConfig(address _creator, bytes32 _merkleRoot) external view returns (AllowListConfig memory);
}
