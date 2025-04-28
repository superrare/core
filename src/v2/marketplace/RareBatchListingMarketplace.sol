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
import {IRareBatchListingMarketplace} from "./IRareBatchListingMarketplace.sol";

/**
 * @title RareBatchListingMarketplace
 * @notice V2 implementation of the RareBatchListingMarketplace, using Merkle-based sale price functionality
 */
contract RareBatchListingMarketplace is IRareBatchListingMarketplace, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using EnumerableSet for EnumerableSet.Bytes32Set;
  using MarketUtilsV2 for MarketConfigV2.Config;
  using MarketConfigV2 for MarketConfigV2.Config;

  /*//////////////////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////////////////*/

  /// @notice Market configuration
  MarketConfigV2.Config internal _marketConfig;

  /// @notice Mapping from creator to all their sale price Merkle roots
  mapping(address => EnumerableSet.Bytes32Set) private _creatorSalePriceMerkleRoots;

  /// @notice Mapping from (creator, root) to MerkleSalePriceConfig
  mapping(address => mapping(bytes32 => MerkleSalePriceConfig)) public creatorRootToConfig;

  /// @notice Mapping from (creator, root) to nonce for that root
  mapping(address => mapping(bytes32 => uint256)) private _creatorRootNonce;

  /// @notice Mapping of keccak256(creator, root, tokenContract, tokenId) to nonce
  mapping(bytes32 => uint256) private _tokenSalePriceNonce;

  /// @notice Delay required before an offer can be cancelled (in seconds)
  uint256 public constant OFFER_CANCELATION_DELAY = 2 minutes;

  /*//////////////////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////////////////*/

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /*//////////////////////////////////////////////////////////////////////////
                                Initializer
    //////////////////////////////////////////////////////////////////////////*/

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
    _marketConfig = MarketConfigV2.generateMarketConfig(
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

    __Ownable_init();
    __ReentrancyGuard_init();
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function registerSalePriceMerkleRoot(
    bytes32 _merkleRoot,
    address _currency,
    uint256 _amount,
    address payable[] calldata _splitAddresses,
    uint8[] calldata _splitRatios
  ) external override {
    // Validate currency
    _marketConfig.checkIfCurrencyIsApproved(_currency);

    // Validate amount within bounds
    require(
      _amount <= _marketConfig.marketplaceSettings.getMarketplaceMaxValue() &&
        _amount >= _marketConfig.marketplaceSettings.getMarketplaceMinValue(),
      "registerSalePriceMerkleRoot::Amount outside bounds"
    );

    // Validate splits
    MarketUtilsV2.checkSplits(_splitAddresses, _splitRatios);

    // Add root to user's set of roots
    _creatorSalePriceMerkleRoots[msg.sender].add(_merkleRoot);

    // Calculate new nonce
    uint256 newNonce = _creatorRootNonce[msg.sender][_merkleRoot] + 1;
    _creatorRootNonce[msg.sender][_merkleRoot] = newNonce;

    // Store configuration
    creatorRootToConfig[msg.sender][_merkleRoot] = MerkleSalePriceConfig({
      currency: _currency,
      amount: _amount,
      splitRecipients: _splitAddresses,
      splitRatios: _splitRatios,
      nonce: newNonce
    });

    emit SalePriceMerkleRootRegistered(msg.sender, _merkleRoot, _currency, _amount, newNonce);
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function buyWithMerkleProof(
    address _originContract,
    uint256 _tokenId,
    address _creator,
    bytes32 _merkleRoot,
    bytes32[] calldata _proof
  ) external payable override {
    // Verify token is in Merkle root
    bytes32 leaf = keccak256(abi.encodePacked(_originContract, _tokenId));
    require(MerkleProof.verify(_proof, _merkleRoot, leaf), "buyWithMerkleProof::Invalid Merkle proof");

    // Verify Merkle root is registered and active
    require(
      _creatorSalePriceMerkleRoots[_creator].contains(_merkleRoot),
      "buyWithMerkleProof::Merkle root not registered"
    );

    // Get config for this Merkle root
    MerkleSalePriceConfig memory config = creatorRootToConfig[_creator][_merkleRoot];

    // Get token nonce key and verify it hasn't been used
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(_creator, _merkleRoot, _originContract, _tokenId));
    uint256 currentNonce = _creatorRootNonce[_creator][_merkleRoot];
    require(
      _tokenSalePriceNonce[tokenNonceKey] < currentNonce,
      "buyWithMerkleProof::Token already used for this Merkle root"
    );

    // Verify creator owns the token
    IERC721 erc721 = IERC721(_originContract);
    address tokenOwner = erc721.ownerOf(_tokenId);
    require(tokenOwner == _creator, "buyWithMerkleProof::Not token owner");

    // Check marketplace approval
    _marketConfig.addressMustHaveMarketplaceApprovedForNFT(_creator, _originContract, _tokenId);

    // Calculate and transfer payment
    uint256 requiredAmount = config.amount + _marketConfig.marketplaceSettings.calculateMarketplaceFee(config.amount);
    MarketUtilsV2.checkAmountAndTransfer(_marketConfig, config.currency, requiredAmount);

    // Update token nonce to current creatorRootNonce
    _tokenSalePriceNonce[tokenNonceKey] = currentNonce;

    // Transfer NFT
    MarketUtilsV2.transferERC721(_marketConfig, _originContract, _creator, msg.sender, _tokenId);

    // Process payment
    _marketConfig.payout(
      _originContract,
      _tokenId,
      config.currency,
      config.amount,
      _creator,
      config.splitRecipients,
      config.splitRatios
    );

    // Mark token as sold
    _marketConfig.marketplaceSettings.markERC721Token(_originContract, _tokenId, true);

    emit MerkleSalePriceExecuted(
      _originContract,
      _tokenId,
      msg.sender,
      _creator,
      _merkleRoot,
      config.amount,
      currentNonce
    );
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function isTokenInRoot(
    bytes32 _root,
    address _origin,
    uint256 _tokenId,
    bytes32[] calldata _proof
  ) external pure override returns (bool) {
    bytes32 leaf = keccak256(abi.encodePacked(_origin, _tokenId));
    return MerkleProof.verify(_proof, _root, leaf);
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function getTokenSalePriceNonce(
    address _creator,
    bytes32 _root,
    address _tokenContract,
    uint256 _tokenId
  ) external view override returns (uint256) {
    bytes32 tokenNonceKey = keccak256(abi.encodePacked(_creator, _root, _tokenContract, _tokenId));
    return _tokenSalePriceNonce[tokenNonceKey];
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function getUserSalePriceMerkleRoots(address _user) external view override returns (bytes32[] memory) {
    return _creatorSalePriceMerkleRoots[_user].values();
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function getCreatorSalePriceMerkleRootNonce(address _user, bytes32 _root) external view override returns (uint256) {
    return _creatorRootNonce[_user][_root];
  }

  /// @inheritdoc IRareBatchListingMarketplace
  function getMerkleSalePriceConfig(
    address _creator,
    bytes32 _root
  ) external view override returns (MerkleSalePriceConfig memory) {
    return creatorRootToConfig[_creator][_root];
  }
}
