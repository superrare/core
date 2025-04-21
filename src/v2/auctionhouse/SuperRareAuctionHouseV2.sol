// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {MarketUtilsV2} from "../../utils/v2/MarketUtilsV2.sol";
import {MarketConfigV2} from "../../utils/v2/MarketConfigV2.sol";
import {ISuperRareAuctionHouseV2} from "./ISuperRareAuctionHouseV2.sol";
import {MerkleProof} from "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";

/// @author SuperRare Labs
/// @title SuperRareAuctionHouseV2
/// @notice The logic for all functions related to the SuperRareAuctionHouseV2.
/// @dev This contract consolidates standard auction functionality from the SuperRare Bazaar
/// with the existing Merkle auction features, ensuring full adoption of MarketUtilsV2.
contract SuperRareAuctionHouseV2 is ISuperRareAuctionHouseV2, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.Bytes32Set;

  // Constants
  bytes32 public constant NO_AUCTION = keccak256("NO_AUCTION");
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

  // Mapping from (creator, root, token contract, token ID) to auction nonce
  // Used to prevent replay attacks when bidding with the same token in multiple auctions
  mapping(address => mapping(bytes32 => mapping(address => mapping(uint256 => uint256)))) private tokenAuctionNonce;

  /**
   * @dev Initializer function
   */
  function initialize(
    address _marketplaceSettings,
    address _royaltyRegistry,
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
    require(_royaltyRegistry != address(0), "initialize::royaltyRegistry cannot be 0 address");
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
    minimumBidIncreasePercentage = 10;
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

  /// @notice Sets the marketplace settings address
  /// @param _marketplaceSettings The new marketplace settings address
  function setMarketplaceSettings(address _marketplaceSettings) external onlyOwner {
    require(_marketplaceSettings != address(0), "setMarketplaceSettings::Cannot be 0 address");
    MarketConfigV2.updateMarketplaceSettings(marketConfig, _marketplaceSettings);
  }

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

  /// @notice Sets the royalty registry address
  /// @param _royaltyEngine The new royalty engine address
  function setRoyaltyEngine(address _royaltyEngine) external onlyOwner {
    require(_royaltyEngine != address(0), "setRoyaltyEngine::Cannot be 0 address");
    MarketConfigV2.updateRoyaltyEngine(marketConfig, _royaltyEngine);
  }

  /// @notice Sets the space operator registry address
  /// @param _spaceOperatorRegistry The new space operator registry address
  function setSpaceOperatorRegistry(address _spaceOperatorRegistry) external onlyOwner {
    require(_spaceOperatorRegistry != address(0), "setSpaceOperatorRegistry::Cannot be 0 address");
    MarketConfigV2.updateSpaceOperatorRegistry(marketConfig, _spaceOperatorRegistry);
  }

  /// @notice Sets the payments address
  /// @param _payments The new payments address
  function setPayments(address _payments) external onlyOwner {
    require(_payments != address(0), "setPayments::Cannot be 0 address");
    MarketConfigV2.updatePayments(marketConfig, _payments);
  }

  /// @notice Sets the approved token registry address
  /// @param _approvedTokenRegistry The new approved token registry address
  function setApprovedTokenRegistry(address _approvedTokenRegistry) external onlyOwner {
    require(_approvedTokenRegistry != address(0), "setApprovedTokenRegistry::Cannot be 0 address");
    MarketConfigV2.updateApprovedTokenRegistry(marketConfig, _approvedTokenRegistry);
  }

  /// @notice Sets the staking settings address
  /// @param _stakingSettings The new staking settings address
  function setStakingSettings(address _stakingSettings) external onlyOwner {
    require(_stakingSettings != address(0), "setStakingSettings::Cannot be 0 address");
    MarketConfigV2.updateStakingSettings(marketConfig, _stakingSettings);
  }

  /// @notice Sets the staking registry address
  /// @param _stakingRegistry The new staking registry address
  function setStakingRegistry(address _stakingRegistry) external onlyOwner {
    require(_stakingRegistry != address(0), "setStakingRegistry::Cannot be 0 address");
    MarketConfigV2.updateStakingRegistry(marketConfig, _stakingRegistry);
  }

  /// @notice Sets the network beneficiary address
  /// @param _networkBeneficiary The new network beneficiary address
  function setNetworkBeneficiary(address _networkBeneficiary) external onlyOwner {
    require(_networkBeneficiary != address(0), "setNetworkBeneficiary::Cannot be 0 address");
    MarketConfigV2.updateNetworkBeneficiary(marketConfig, _networkBeneficiary);
  }

  /// @notice Sets the ERC20 approval manager address
  /// @param _erc20ApprovalManager The new ERC20 approval manager address
  function setERC20ApprovalManager(address _erc20ApprovalManager) external onlyOwner {
    require(_erc20ApprovalManager != address(0), "setERC20ApprovalManager::Cannot be 0 address");
    MarketConfigV2.updateERC20ApprovalManager(marketConfig, _erc20ApprovalManager);
  }

  /// @notice Sets the ERC721 approval manager address
  /// @param _erc721ApprovalManager The new ERC721 approval manager address
  function setERC721ApprovalManager(address _erc721ApprovalManager) external onlyOwner {
    require(_erc721ApprovalManager != address(0), "setERC721ApprovalManager::Cannot be 0 address");
    MarketConfigV2.updateERC721ApprovalManager(marketConfig, _erc721ApprovalManager);
  }

  // Implementation of functions will be completed in subsequent phases

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
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Cancels a configured Auction that has not started.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function cancelAuction(address _originContract, uint256 _tokenId) external override {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Places a bid on a valid auction.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function bid(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount
  ) external payable override nonReentrant {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Settles an auction that has ended.
  /// @inheritdoc ISuperRareAuctionHouseV2
  function settleAuction(address _originContract, uint256 _tokenId) external override {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
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
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
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
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Cancels a previously registered Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function cancelAuctionMerkleRoot(bytes32 root) external override {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
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
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Gets all Merkle roots registered by a user
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getUserAuctionMerkleRoots(address user) external view override returns (bytes32[] memory) {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Gets the current nonce for a user's Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getCreatorAuctionMerkleRootNonce(address user, bytes32 root) external view override returns (uint256) {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Verifies if a token is included in a Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function isTokenInRoot(
    bytes32 root,
    address origin,
    uint256 tokenId,
    bytes32[] calldata proof
  ) external pure override returns (bool) {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Gets the Merkle auction configuration for a given creator and root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getMerkleAuctionConfig(
    address creator,
    bytes32 root
  ) external view override returns (MerkleAuctionConfig memory) {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
  }

  /// @notice Gets the nonce for a specific token under a Merkle root
  /// @inheritdoc ISuperRareAuctionHouseV2
  function getTokenAuctionNonce(
    address creator,
    bytes32 root,
    address tokenContract,
    uint256 tokenId
  ) external view override returns (uint256) {
    // Implementation will be completed in Phase 2
    revert("Not yet implemented");
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
