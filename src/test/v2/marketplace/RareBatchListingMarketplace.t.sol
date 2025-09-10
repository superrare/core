// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";

import {RareBatchListingMarketplace} from "../../../v2/marketplace/RareBatchListingMarketplace.sol";
import {IRareBatchListingMarketplace} from "../../../v2/marketplace/IRareBatchListingMarketplace.sol";
import {IStakingSettings} from "../../../marketplace/IStakingSettings.sol";
import {TestNFT} from "../utils/TestNft.sol";
import {TestToken} from "../utils/TestToken.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MarketConfigV2} from "../../../v2/utils/MarketConfigV2.sol";

/// @title RareBatchListingMarketplaceTest
/// @notice Tests for the Merkle sale price functionality in RareBatchListingMarketplace
contract RareBatchListingMarketplaceTest is Test {
  RareBatchListingMarketplace public marketplace;
  RareBatchListingMarketplace public marketplaceImplementation;

  // Mock addresses for dependencies
  address private _marketplaceSettings = makeAddr("marketplaceSettings");
  address private _royaltyEngine = makeAddr("royaltyEngine");
  address private _spaceOperatorRegistry = makeAddr("spaceOperatorRegistry");
  address private _approvedTokenRegistry = makeAddr("approvedTokenRegistry");
  address private _payments = makeAddr("payments");
  address private _stakingRegistry = makeAddr("stakingRegistry");
  address private _stakingSettings = makeAddr("stakingSettings");
  address private _networkBeneficiary = makeAddr("networkBeneficiary");

  // Test contracts
  TestNFT public nftContract;
  TestToken public currencyContract;
  ERC20ApprovalManager public erc20ApprovalManager;
  ERC721ApprovalManager public erc721ApprovalManager;

  // Test users
  address public admin;
  address public creator;
  address public buyer;
  address public nonOwner;

  // Test data
  uint256 public tokenId;
  bytes32 public merkleRoot;
  bytes32[] public merkleProof;
  IRareBatchListingMarketplace.MerkleSalePriceConfig public salePriceConfig;

  // Helper contract
  Merkle public merkle;

  // Constants
  uint256 public constant SALE_PRICE = 1 ether;
  uint8 public constant SPLIT_RATIO = 100;

  function setUp() public {
    // Setup test users
    admin = makeAddr("admin");
    creator = makeAddr("creator");
    buyer = makeAddr("buyer");
    nonOwner = makeAddr("nonOwner");

    // Deploy approval managers first
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();

    // Deploy other contracts
    marketplaceImplementation = new RareBatchListingMarketplace();
    marketplace = RareBatchListingMarketplace(address(new ERC1967Proxy(address(marketplaceImplementation), "")));
    merkle = new Merkle();
    nftContract = new TestNFT();
    currencyContract = new TestToken();

    // Initialize marketplace with approval managers
    marketplace.initialize(
      _marketplaceSettings,
      _royaltyEngine,
      _spaceOperatorRegistry,
      _approvedTokenRegistry,
      _payments,
      _stakingRegistry,
      _stakingSettings,
      _networkBeneficiary,
      address(erc20ApprovalManager),
      address(erc721ApprovalManager)
    );

    // Set up approval manager roles - admin must be the DEFAULT_ADMIN_ROLE first
    vm.startPrank(address(this)); // The test contract deploys the approval managers, so it has DEFAULT_ADMIN_ROLE
    erc20ApprovalManager.grantRole(erc20ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);
    erc721ApprovalManager.grantRole(erc721ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);
    vm.stopPrank();

    // Now admin can grant OPERATOR_ROLE to the marketplace
    vm.startPrank(admin);
    erc20ApprovalManager.grantRole(erc20ApprovalManager.OPERATOR_ROLE(), address(marketplace));
    erc721ApprovalManager.grantRole(erc721ApprovalManager.OPERATOR_ROLE(), address(marketplace));
    vm.stopPrank();

    // Setup test NFTs - mint multiple tokens to create a proper Merkle tree
    uint256[] memory tokenIds = nftContract.mintBatch(creator, 3);
    tokenId = tokenIds[0]; // Use the first token for our test

    // Setup creator's NFT approval
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    // Setup sale price config
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(makeAddr("splitRecipient"));
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    salePriceConfig = IRareBatchListingMarketplace.MerkleSalePriceConfig({
      currency: address(currencyContract),
      amount: SALE_PRICE,
      splitRecipients: splitAddresses,
      splitRatios: splitRatios,
      nonce: 0
    });

    // Setup Merkle tree with multiple tokens
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenIds[i];
    }
    (merkleRoot, merkleProof) = _createMerkleTree(contracts, ids, 0); // Get proof for first token (index 0)

    // Fund test users
    vm.deal(admin, 10 ether);
    vm.deal(creator, 10 ether);
    vm.deal(buyer, 10 ether);

    // Fund users with test tokens
    currencyContract.mint(buyer, 1000 * 10 ** currencyContract.decimals());

    // Default Mocks
    // Mock marketplace settings
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(uint8(3))
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMaxValue.selector),
      abi.encode(type(uint256).max)
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMinValue.selector),
      abi.encode(uint256(0))
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, SALE_PRICE),
      abi.encode((SALE_PRICE * 3) / 100)
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nftContract), 3),
      abi.encode(false)
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(
        IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector,
        address(nftContract)
      ),
      abi.encode(15)
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(nftContract)),
      abi.encode()
    );
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nftContract)),
      abi.encode(false)
    );

    // Mock staking settings
    vm.mockCall(
      _stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, SALE_PRICE),
      abi.encode((SALE_PRICE * 3) / 100)
    );
    vm.mockCall(_stakingSettings, abi.encodeWithSignature("calculateStakingFee(uint256)"), abi.encode(0));

    // Mock royalty engine
    vm.mockCall(
      _royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyaltyView.selector),
      abi.encode(new address payable[](0), new uint256[](0))
    );
    vm.mockCall(
      _royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    // Mock space operator registry
    vm.mockCall(
      _spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector),
      abi.encode(true)
    );
    vm.mockCall(
      _spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector),
      abi.encode(uint8(0))
    );

    // Mock approved token registry
    vm.mockCall(
      _approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector),
      abi.encode(true)
    );

    // Mock payments
    vm.mockCall(_payments, abi.encodeWithSelector(IPayments.refund.selector), abi.encode());
    vm.mockCall(_payments, abi.encodeWithSelector(IPayments.payout.selector), abi.encode());

    // Mock staking registry
    vm.mockCall(
      _stakingRegistry,
      abi.encodeWithSelector(bytes4(keccak256("getRewardAccumulatorAddressForUser(address)"))),
      abi.encode(address(0))
    );
  }

  /// @dev Helper function to create a Merkle tree and get proof for a specific token
  function _createMerkleTree(
    address[] memory _contracts,
    uint256[] memory _tokenIds,
    uint256 _proofIndex
  ) internal returns (bytes32 root, bytes32[] memory proof) {
    require(_contracts.length == _tokenIds.length, "_createMerkleTree: Array lengths must match");
    require(_proofIndex < _contracts.length, "_createMerkleTree: Proof index out of bounds");

    bytes32[] memory leaves = new bytes32[](_contracts.length);
    for (uint256 i = 0; i < _contracts.length; i++) {
      leaves[i] = keccak256(abi.encodePacked(_contracts[i], _tokenIds[i]));
    }

    root = merkle.getRoot(leaves);
    proof = merkle.getProof(leaves, _proofIndex);

    return (root, proof);
  }

  /// @dev Helper function to create fresh tokens and Merkle tree
  function _createFreshMerkleTree(
    uint256 _numTokens
  ) internal returns (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) {
    require(_numTokens > 0, "_createFreshMerkleTree: Must create at least one token");

    // Mint new tokens
    tokenIds = nftContract.mintBatch(creator, _numTokens);
    firstTokenId = tokenIds[0];

    // Setup creator's NFT approval
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    // Create arrays for Merkle tree
    address[] memory contracts = new address[](_numTokens);
    for (uint256 i = 0; i < _numTokens; i++) {
      contracts[i] = address(nftContract);
    }

    // Create Merkle tree and get proof for first token
    (root, proof) = _createMerkleTree(contracts, tokenIds, 0);

    return (root, proof, tokenIds, firstTokenId);
  }

  function test_registerSalePriceMerkleRoot_success() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Verify the root was registered
    bytes32[] memory roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 1, "Should have one root registered");
    assertEq(roots[0], root, "Registered root should match");

    // Verify the nonce was incremented
    uint256 nonce = marketplace.getCreatorSalePriceMerkleRootNonce(creator, root);
    assertEq(nonce, 1, "Nonce should be 1");

    vm.stopPrank();
  }

  function test_registerSalePriceMerkleRoot_invalidCurrency() public {
    // Create an invalid currency contract
    TestToken invalidCurrency = new TestToken();

    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Mock the currency check to return false
    vm.mockCall(
      _approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(invalidCurrency)),
      abi.encode(false)
    );

    // Try to register with invalid currency
    vm.startPrank(creator);
    vm.expectRevert("Not approved currency");
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(invalidCurrency),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();
  }

  function test_registerSalePriceMerkleRoot_invalidSplits() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Create invalid splits (ratios don't sum to 100)
    address payable[] memory invalidSplitAddresses = new address payable[](2);
    invalidSplitAddresses[0] = payable(makeAddr("splitRecipient1"));
    invalidSplitAddresses[1] = payable(makeAddr("splitRecipient2"));
    uint8[] memory invalidSplitRatios = new uint8[](2);
    invalidSplitRatios[0] = 60;
    invalidSplitRatios[1] = 60; // Total 120%, should fail

    // Try to register with invalid splits
    vm.startPrank(creator);
    vm.expectRevert("checkSplits::Total must be equal to 100");
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      invalidSplitAddresses,
      invalidSplitRatios
    );
    vm.stopPrank();
  }

  function test_registerSalePriceMerkleRoot_invalidAmount() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Mock max value to be lower than our test amount
    vm.mockCall(
      _marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMaxValue.selector),
      abi.encode(SALE_PRICE / 2)
    );

    // Try to register with amount exceeding max value
    vm.startPrank(creator);
    vm.expectRevert("registerSalePriceMerkleRoot::Amount outside bounds");
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_success() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    vm.stopPrank();

    // Execute purchase
    vm.startPrank(buyer);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();

    // Verify token ownership changed
    assertEq(nftContract.ownerOf(firstTokenId), buyer, "Buyer should own the token");

    // Verify token nonce was updated
    uint256 tokenNonce = marketplace.getTokenSalePriceNonce(creator, root, address(nftContract), firstTokenId);
    assertEq(tokenNonce, 1, "Token nonce should be 1");
  }

  function test_buyWithMerkleProof_invalidProof() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory validProof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Create invalid proof by modifying the valid proof
    bytes32[] memory invalidProof = new bytes32[](validProof.length);
    for (uint256 i = 0; i < validProof.length; i++) {
      invalidProof[i] = bytes32(uint256(validProof[i]) + 1); // Modify each element
    }

    // Setup buyer approval
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to buy with invalid proof
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    vm.expectRevert("buyWithMerkleProof::Invalid Merkle proof");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      invalidProof,
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_replayProtection() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Setup buyer approval for multiple purchases
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount * 2);

    bytes32[] memory emptyAllowListProof = new bytes32[](0);

    // First purchase should succeed
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );

    // Second purchase should fail
    vm.expectRevert("buyWithMerkleProof::Token already used for this Merkle root");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_ownershipVerification() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Transfer token to buyer
    nftContract.transferFrom(creator, buyer, firstTokenId);
    vm.stopPrank();

    // Setup buyer approval
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to buy when creator no longer owns the token
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    vm.expectRevert("buyWithMerkleProof::Not token owner");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_ethPayment() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(0), // ETH
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Calculate required amount including fee
    uint256 marketplaceFee = IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    uint256 requiredAmount = SALE_PRICE + marketplaceFee;

    // Execute purchase with ETH
    vm.startPrank(buyer);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    marketplace.buyWithMerkleProof{value: requiredAmount}(
      address(nftContract),
      firstTokenId,
      address(0),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();

    // Verify token ownership changed
    assertEq(nftContract.ownerOf(firstTokenId), buyer, "Buyer should own the token");

    // Verify contract ETH balance
    assertEq(address(marketplace).balance, requiredAmount, "Marketplace ETH balance incorrect");
  }

  function test_buyWithMerkleProof_insufficientBalance() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root with ETH as currency
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(0), // ETH
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Try to purchase with insufficient ETH
    vm.startPrank(buyer);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    vm.expectRevert("not enough eth sent");
    marketplace.buyWithMerkleProof{value: SALE_PRICE / 2}(
      address(nftContract),
      firstTokenId,
      address(0),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_gasLargeMerkleTree() public {
    uint256 numTokens = 1000;

    // Create large Merkle tree
    address[] memory contracts = new address[](numTokens);
    uint256[] memory ids = new uint256[](numTokens);
    uint256 targetTokenId;

    // Mint tokens and prepare arrays
    vm.startPrank(creator);
    for (uint256 i = 0; i < numTokens; i++) {
      uint256 newTokenId = nftContract.mint(creator);
      if (i == numTokens / 2) {
        targetTokenId = newTokenId; // Use middle token for test
      }
      contracts[i] = address(nftContract);
      ids[i] = newTokenId;
    }
    vm.stopPrank();

    // Create Merkle tree and get proof for target token
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, numTokens / 2);

    // Register root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(0), // ETH
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Calculate required amount including fee
    uint256 marketplaceFee = IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    uint256 requiredAmount = SALE_PRICE + marketplaceFee;

    // Execute purchase and measure gas
    vm.startPrank(buyer);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    marketplace.buyWithMerkleProof{value: requiredAmount}(
      address(nftContract),
      targetTokenId,
      address(0),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();

    // Verify purchase was successful
    assertEq(nftContract.ownerOf(targetTokenId), buyer, "Buyer should own the token");
  }

  function test_buyWithMerkleProof_nonExistentRoot() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Try to buy with unregistered root
    vm.startPrank(buyer);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);
    vm.expectRevert("buyWithMerkleProof::Merkle root not registered");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_multipleTokens() public {
    // Create fresh tokens and Merkle tree with multiple tokens
    (bytes32 root, , uint256[] memory tokenIds, ) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Setup buyer approval for multiple purchases
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount * 3); // Approve for all tokens
    vm.stopPrank();

    bytes32[] memory emptyAllowListProof = new bytes32[](0);

    // Buy each token
    for (uint256 i = 0; i < tokenIds.length; i++) {
      // Get proof for current token
      (, bytes32[] memory proof) = _createMerkleTree(
        _createContractArray(address(nftContract), tokenIds.length),
        tokenIds,
        i
      );

      vm.startPrank(buyer);
      marketplace.buyWithMerkleProof(
        address(nftContract),
        tokenIds[i],
        address(currencyContract),
        SALE_PRICE,
        creator,
        root,
        proof,
        emptyAllowListProof
      );
      vm.stopPrank();

      // Verify ownership
      assertEq(nftContract.ownerOf(tokenIds[i]), buyer, string.concat("Buyer should own token ", vm.toString(i)));
    }
  }

  function test_isTokenInRoot_success() public {
    // Create Merkle tree with multiple tokens
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = i + 1;
    }

    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    // Test valid token
    bool isValid = marketplace.isTokenInRoot(root, contracts[0], ids[0], proof);
    assertTrue(isValid, "Token should be in root");

    // Test invalid token (modify token ID)
    bool isInvalid = marketplace.isTokenInRoot(root, contracts[0], 999, proof);
    assertFalse(isInvalid, "Token should not be in root");
  }

  /// @dev Helper function to create an array of identical contract addresses
  function _createContractArray(address _contract, uint256 _length) internal pure returns (address[] memory) {
    address[] memory contracts = new address[](_length);
    for (uint256 i = 0; i < _length; i++) {
      contracts[i] = _contract;
    }
    return contracts;
  }

  function test_setAllowListConfig_success() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Create allowlist Merkle tree
    address[] memory allowedAddresses = new address[](2);
    allowedAddresses[0] = buyer;
    allowedAddresses[1] = makeAddr("otherBuyer");

    bytes32[] memory allowListLeaves = new bytes32[](2);
    for (uint256 i = 0; i < allowedAddresses.length; i++) {
      allowListLeaves[i] = keccak256(abi.encodePacked(allowedAddresses[i]));
    }
    bytes32 allowListRoot = merkle.getRoot(allowListLeaves);
    uint256 endTimestamp = block.timestamp + 1 days;

    // Set allowlist config
    marketplace.setAllowListConfig(root, allowListRoot, endTimestamp);

    // Verify config was set correctly
    IRareBatchListingMarketplace.AllowListConfig memory config = marketplace.getAllowListConfig(creator, root);
    assertEq(config.root, allowListRoot, "Allowlist root should match");
    assertEq(config.endTimestamp, endTimestamp, "End timestamp should match");

    vm.stopPrank();
  }

  function test_setAllowListConfig_notRootOwner() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Try to set allowlist config without owning the root
    vm.startPrank(buyer);
    vm.expectRevert("setAllowListConfig::Not root owner");
    marketplace.setAllowListConfig(root, bytes32(0), block.timestamp + 1 days);
    vm.stopPrank();
  }

  function test_setAllowListConfig_endTimestampInPast() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the sale price merkle root first
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Try to set allowlist config with end timestamp in the past
    vm.expectRevert("setAllowListConfig::Allow-list end must be in the future");
    marketplace.setAllowListConfig(root, bytes32(uint256(1)), block.timestamp - 1);

    // Try to set allowlist config with end timestamp equal to current timestamp
    vm.expectRevert("setAllowListConfig::Allow-list end must be in the future");
    marketplace.setAllowListConfig(root, bytes32(uint256(1)), block.timestamp);

    vm.stopPrank();
  }

  function test_buyWithMerkleProof_withAllowList_success() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Create allowlist Merkle tree with buyer and another address
    address[] memory allowedAddresses = new address[](2);
    allowedAddresses[0] = buyer;
    allowedAddresses[1] = makeAddr("otherAllowedUser");

    bytes32[] memory allowListLeaves = new bytes32[](2);
    allowListLeaves[0] = keccak256(abi.encodePacked(buyer));
    allowListLeaves[1] = keccak256(abi.encodePacked(allowedAddresses[1]));
    bytes32 allowListRoot = merkle.getRoot(allowListLeaves);
    bytes32[] memory allowListProof = merkle.getProof(allowListLeaves, 0); // Get proof for buyer's address

    // Set allowlist config
    marketplace.setAllowListConfig(root, allowListRoot, block.timestamp + 1 days);
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Execute purchase with allowlist proof
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      allowListProof
    );
    vm.stopPrank();

    // Verify token ownership changed
    assertEq(nftContract.ownerOf(firstTokenId), buyer, "Buyer should own the token");
  }

  function test_buyWithMerkleProof_withAllowList_notAllowed() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Create allowlist Merkle tree without buyer
    address[] memory allowedAddresses = new address[](2);
    allowedAddresses[0] = makeAddr("allowedUser1");
    allowedAddresses[1] = makeAddr("allowedUser2");

    bytes32[] memory allowListLeaves = new bytes32[](2);
    allowListLeaves[0] = keccak256(abi.encodePacked(allowedAddresses[0]));
    allowListLeaves[1] = keccak256(abi.encodePacked(allowedAddresses[1]));
    bytes32 allowListRoot = merkle.getRoot(allowListLeaves);
    bytes32[] memory allowListProof = merkle.getProof(allowListLeaves, 0); // Use first address's proof

    // Set allowlist config
    marketplace.setAllowListConfig(root, allowListRoot, block.timestamp + 1 days);
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to purchase without being on allowlist
    vm.expectRevert("buyWithMerkleProof::Not on allowlist");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      allowListProof
    );
    vm.stopPrank();
  }

  function test_buyWithMerkleProof_withAllowList_expired() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Create allowlist Merkle tree with buyer and another address
    address[] memory allowedAddresses = new address[](2);
    allowedAddresses[0] = buyer;
    allowedAddresses[1] = makeAddr("otherAllowedUser");

    bytes32[] memory allowListLeaves = new bytes32[](2);
    allowListLeaves[0] = keccak256(abi.encodePacked(buyer));
    allowListLeaves[1] = keccak256(abi.encodePacked(allowedAddresses[1]));
    bytes32 allowListRoot = merkle.getRoot(allowListLeaves);
    bytes32[] memory allowListProof = merkle.getProof(allowListLeaves, 0); // Get proof for buyer's address

    // Set allowlist config with future timestamp
    uint256 endTimestamp = block.timestamp + 1 hours;
    marketplace.setAllowListConfig(root, allowListRoot, endTimestamp);
    vm.stopPrank();

    // Warp time to after the allowlist expiration
    vm.warp(endTimestamp + 1);

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to purchase after allowlist expired
    vm.expectRevert("buyWithMerkleProof::Allowlist period has ended");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      allowListProof
    );
    vm.stopPrank();
  }

  function test_cancelSalePriceMerkleRoot() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Verify root is registered
    bytes32[] memory roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 1, "Root should be registered");

    // Set allowlist config to verify it gets cleaned up
    vm.startPrank(creator);
    marketplace.setAllowListConfig(root, bytes32(uint256(1)), block.timestamp + 1 days);
    vm.stopPrank();

    // Verify allowlist config exists
    IRareBatchListingMarketplace.AllowListConfig memory allowListConfig = marketplace.getAllowListConfig(creator, root);
    assertEq(allowListConfig.root, bytes32(uint256(1)), "Allowlist should be set");

    // Cancel the root
    vm.startPrank(creator);
    marketplace.cancelSalePriceMerkleRoot(root);
    vm.stopPrank();

    // Verify root is removed
    roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 0, "Root should be removed");

    // Verify config is cleaned up
    IRareBatchListingMarketplace.MerkleSalePriceConfig memory config = marketplace.getMerkleSalePriceConfig(
      creator,
      root
    );
    assertEq(config.currency, address(0), "Config should be cleaned up");
    assertEq(config.amount, 0, "Config should be cleaned up");

    // Verify allowlist config is cleaned up
    allowListConfig = marketplace.getAllowListConfig(creator, root);
    assertEq(allowListConfig.root, bytes32(0), "Allowlist should be cleaned up");
    assertEq(allowListConfig.endTimestamp, 0, "Allowlist should be cleaned up");

    // Verify nonce is preserved
    uint256 nonce = marketplace.getCreatorSalePriceMerkleRootNonce(creator, root);
    assertEq(nonce, 1, "Nonce should be preserved");
  }

  function test_cancelSalePriceMerkleRoot_notOwner() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(creator);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Try to cancel as non-owner
    vm.startPrank(buyer);
    vm.expectRevert("cancelSalePriceMerkleRoot::Not root owner");
    marketplace.cancelSalePriceMerkleRoot(root);
    vm.stopPrank();

    // Verify root is still registered
    bytes32[] memory roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 1, "Root should still be registered");
  }

  function test_cancelSalePriceMerkleRoot_nonexistentRoot() public {
    bytes32 nonexistentRoot = bytes32(uint256(1));

    // Try to cancel non-existent root
    vm.startPrank(creator);
    vm.expectRevert("cancelSalePriceMerkleRoot::Not root owner");
    marketplace.cancelSalePriceMerkleRoot(nonexistentRoot);
    vm.stopPrank();
  }

  /// @notice Test that zero-length Merkle proofs are rejected for token verification
  function test_buyWithMerkleProof_zeroLengthProofRejected() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to buy with zero-length proof (should fail)
    bytes32[] memory emptyProof = new bytes32[](0);
    bytes32[] memory emptyAllowListProof = new bytes32[](0);

    vm.expectRevert("buyWithMerkleProof::Proof cannot be empty");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      emptyProof, // Zero-length proof
      emptyAllowListProof
    );
    vm.stopPrank();
  }

  /// @notice Test that zero-length allowlist proofs are rejected when allowlist is configured
  function test_buyWithMerkleProof_zeroLengthAllowListProofRejected() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the sale price merkle root
    vm.startPrank(creator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );

    // Create allowlist Merkle tree with buyer and another address
    address[] memory allowedAddresses = new address[](2);
    allowedAddresses[0] = buyer;
    allowedAddresses[1] = makeAddr("otherAllowedUser");

    bytes32[] memory allowListLeaves = new bytes32[](2);
    allowListLeaves[0] = keccak256(abi.encodePacked(buyer));
    allowListLeaves[1] = keccak256(abi.encodePacked(allowedAddresses[1]));
    bytes32 allowListRoot = merkle.getRoot(allowListLeaves);

    // Set allowlist config
    marketplace.setAllowListConfig(root, allowListRoot, block.timestamp + 1 days);
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to buy with zero-length allowlist proof (should fail)
    bytes32[] memory emptyAllowListProof = new bytes32[](0);

    vm.expectRevert("buyWithMerkleProof::Allowlist proof cannot be empty");
    marketplace.buyWithMerkleProof(
      address(nftContract),
      firstTokenId,
      address(currencyContract),
      SALE_PRICE,
      creator,
      root,
      proof,
      emptyAllowListProof // Zero-length allowlist proof
    );
    vm.stopPrank();
  }

  /// @notice Test that isTokenInRoot returns false for zero-length proofs
  function test_isTokenInRoot_zeroLengthProofReturnsFalse() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Create zero-length proof
    bytes32[] memory emptyProof = new bytes32[](0);

    // Test that zero-length proof returns false
    bool result = marketplace.isTokenInRoot(root, address(nftContract), firstTokenId, emptyProof);
    assertFalse(result, "Zero-length proof should return false");
  }

  /// @notice Test that isTokenInRoot works correctly with valid proofs
  function test_isTokenInRoot_validProofReturnsTrue() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Test that valid proof returns true
    bool result = marketplace.isTokenInRoot(root, address(nftContract), firstTokenId, proof);
    assertTrue(result, "Valid proof should return true");
  }

  /*//////////////////////////////////////////////////////////////////////////
                              UUPS Upgrade Tests
  //////////////////////////////////////////////////////////////////////////*/

  /// @notice Test that owner can upgrade the contract
  function test_upgrade_ownerCanUpgrade() public {
    // Deploy new implementation
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();

    // Owner should be able to upgrade
    marketplace.upgradeTo(address(newImplementation));

    // Verify the upgrade was successful by checking the contract still works
    bytes32[] memory roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 0, "Contract should still function after upgrade");
  }

  /// @notice Test that non-owner cannot upgrade the contract
  function test_upgrade_nonOwnerCannotUpgrade() public {
    // Deploy new implementation
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();

    // Non-owner should not be able to upgrade
    vm.startPrank(buyer);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.upgradeTo(address(newImplementation));
    vm.stopPrank();
  }

  /// @notice Test that owner can upgrade and call initialization in one transaction
  function test_upgrade_upgradeToAndCall() public {
    // Deploy new implementation
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();

    // Prepare call data for a function call after upgrade
    bytes memory callData = abi.encodeWithSelector(marketplace.getUserSalePriceMerkleRoots.selector, creator);

    // Owner should be able to upgrade and call
    marketplace.upgradeToAndCall(address(newImplementation), callData);

    // Verify the contract still works
    bytes32[] memory roots = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(roots.length, 0, "Contract should still function after upgrade");
  }

  /// @notice Test that non-owner cannot use upgradeToAndCall
  function test_upgrade_nonOwnerCannotUpgradeToAndCall() public {
    // Deploy new implementation
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();

    // Prepare call data
    bytes memory callData = abi.encodeWithSelector(marketplace.getUserSalePriceMerkleRoots.selector, creator);

    // Non-owner should not be able to upgrade
    vm.startPrank(buyer);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.upgradeToAndCall(address(newImplementation), callData);
    vm.stopPrank();
  }

  /// @notice Test that upgrade preserves existing state
  function test_upgrade_preservesState() public {
    // Create and register a Merkle root before upgrade
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    vm.startPrank(creator);
    marketplace.registerSalePriceMerkleRoot(
      root,
      address(currencyContract),
      SALE_PRICE,
      salePriceConfig.splitRecipients,
      salePriceConfig.splitRatios
    );
    vm.stopPrank();

    // Verify state before upgrade
    bytes32[] memory rootsBefore = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(rootsBefore.length, 1, "Should have one root before upgrade");
    assertEq(rootsBefore[0], root, "Root should match before upgrade");

    uint256 nonceBefore = marketplace.getCreatorSalePriceMerkleRootNonce(creator, root);
    assertEq(nonceBefore, 1, "Nonce should be 1 before upgrade");

    // Deploy new implementation and upgrade
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();
    marketplace.upgradeTo(address(newImplementation));

    // Verify state is preserved after upgrade
    bytes32[] memory rootsAfter = marketplace.getUserSalePriceMerkleRoots(creator);
    assertEq(rootsAfter.length, 1, "Should have one root after upgrade");
    assertEq(rootsAfter[0], root, "Root should match after upgrade");

    uint256 nonceAfter = marketplace.getCreatorSalePriceMerkleRootNonce(creator, root);
    assertEq(nonceAfter, 1, "Nonce should be preserved after upgrade");

    // Verify config is preserved
    IRareBatchListingMarketplace.MerkleSalePriceConfig memory config = marketplace.getMerkleSalePriceConfig(
      creator,
      root
    );
    assertEq(config.currency, address(currencyContract), "Currency should be preserved");
    assertEq(config.amount, SALE_PRICE, "Amount should be preserved");
    assertEq(config.nonce, 1, "Config nonce should be preserved");
  }

  /*//////////////////////////////////////////////////////////////////////////
                              Admin Configuration Tests
  //////////////////////////////////////////////////////////////////////////*/

  /// @notice Test that owner can update network beneficiary
  function test_admin_setNetworkBeneficiary_success() public {
    address newBeneficiary = makeAddr("newBeneficiary");

    // Owner should be able to update network beneficiary
    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.NetworkBeneficiaryUpdated(newBeneficiary);
    marketplace.setNetworkBeneficiary(newBeneficiary);
  }

  /// @notice Test that non-owner cannot update network beneficiary
  function test_admin_setNetworkBeneficiary_onlyOwner() public {
    address newBeneficiary = makeAddr("newBeneficiary");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setNetworkBeneficiary(newBeneficiary);
    vm.stopPrank();
  }

  /// @notice Test that owner can update marketplace settings
  function test_admin_setMarketplaceSettings_success() public {
    address newSettings = makeAddr("newMarketplaceSettings");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.MarketplaceSettingsUpdated(newSettings);
    marketplace.setMarketplaceSettings(newSettings);
  }

  /// @notice Test that non-owner cannot update marketplace settings
  function test_admin_setMarketplaceSettings_onlyOwner() public {
    address newSettings = makeAddr("newMarketplaceSettings");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setMarketplaceSettings(newSettings);
    vm.stopPrank();
  }

  /// @notice Test that owner can update space operator registry
  function test_admin_setSpaceOperatorRegistry_success() public {
    address newRegistry = makeAddr("newSpaceOperatorRegistry");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.SpaceOperatorRegistryUpdated(newRegistry);
    marketplace.setSpaceOperatorRegistry(newRegistry);
  }

  /// @notice Test that non-owner cannot update space operator registry
  function test_admin_setSpaceOperatorRegistry_onlyOwner() public {
    address newRegistry = makeAddr("newSpaceOperatorRegistry");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setSpaceOperatorRegistry(newRegistry);
    vm.stopPrank();
  }

  /// @notice Test that owner can update royalty engine
  function test_admin_setRoyaltyEngine_success() public {
    address newEngine = makeAddr("newRoyaltyEngine");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.RoyaltyEngineUpdated(newEngine);
    marketplace.setRoyaltyEngine(newEngine);
  }

  /// @notice Test that non-owner cannot update royalty engine
  function test_admin_setRoyaltyEngine_onlyOwner() public {
    address newEngine = makeAddr("newRoyaltyEngine");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setRoyaltyEngine(newEngine);
    vm.stopPrank();
  }

  /// @notice Test that owner can update payments contract
  function test_admin_setPayments_success() public {
    address newPayments = makeAddr("newPayments");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.PaymentsUpdated(newPayments);
    marketplace.setPayments(newPayments);
  }

  /// @notice Test that non-owner cannot update payments contract
  function test_admin_setPayments_onlyOwner() public {
    address newPayments = makeAddr("newPayments");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setPayments(newPayments);
    vm.stopPrank();
  }

  /// @notice Test that owner can update approved token registry
  function test_admin_setApprovedTokenRegistry_success() public {
    address newRegistry = makeAddr("newApprovedTokenRegistry");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.ApprovedTokenRegistryUpdated(newRegistry);
    marketplace.setApprovedTokenRegistry(newRegistry);
  }

  /// @notice Test that non-owner cannot update approved token registry
  function test_admin_setApprovedTokenRegistry_onlyOwner() public {
    address newRegistry = makeAddr("newApprovedTokenRegistry");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setApprovedTokenRegistry(newRegistry);
    vm.stopPrank();
  }

  /// @notice Test that owner can update staking settings
  function test_admin_setStakingSettings_success() public {
    address newSettings = makeAddr("newStakingSettings");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.StakingSettingsUpdated(newSettings);
    marketplace.setStakingSettings(newSettings);
  }

  /// @notice Test that non-owner cannot update staking settings
  function test_admin_setStakingSettings_onlyOwner() public {
    address newSettings = makeAddr("newStakingSettings");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setStakingSettings(newSettings);
    vm.stopPrank();
  }

  /// @notice Test that owner can update staking registry
  function test_admin_setStakingRegistry_success() public {
    address newRegistry = makeAddr("newStakingRegistry");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.StakingRegistryUpdated(newRegistry);
    marketplace.setStakingRegistry(newRegistry);
  }

  /// @notice Test that non-owner cannot update staking registry
  function test_admin_setStakingRegistry_onlyOwner() public {
    address newRegistry = makeAddr("newStakingRegistry");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setStakingRegistry(newRegistry);
    vm.stopPrank();
  }

  /// @notice Test that owner can update ERC20 approval manager
  function test_admin_setERC20ApprovalManager_success() public {
    address newManager = makeAddr("newERC20ApprovalManager");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.ERC20ApprovalManagerUpdated(newManager);
    marketplace.setERC20ApprovalManager(newManager);
  }

  /// @notice Test that non-owner cannot update ERC20 approval manager
  function test_admin_setERC20ApprovalManager_onlyOwner() public {
    address newManager = makeAddr("newERC20ApprovalManager");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setERC20ApprovalManager(newManager);
    vm.stopPrank();
  }

  /// @notice Test that owner can update ERC721 approval manager
  function test_admin_setERC721ApprovalManager_success() public {
    address newManager = makeAddr("newERC721ApprovalManager");

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.ERC721ApprovalManagerUpdated(newManager);
    marketplace.setERC721ApprovalManager(newManager);
  }

  /// @notice Test that non-owner cannot update ERC721 approval manager
  function test_admin_setERC721ApprovalManager_onlyOwner() public {
    address newManager = makeAddr("newERC721ApprovalManager");

    vm.startPrank(nonOwner);
    vm.expectRevert("Ownable: caller is not the owner");
    marketplace.setERC721ApprovalManager(newManager);
    vm.stopPrank();
  }

  /// @notice Test multiple admin updates in sequence
  function test_admin_multipleUpdates() public {
    address newBeneficiary = makeAddr("newBeneficiary");
    address newSettings = makeAddr("newMarketplaceSettings");
    address newRegistry = makeAddr("newSpaceOperatorRegistry");

    // Update multiple settings
    marketplace.setNetworkBeneficiary(newBeneficiary);
    marketplace.setMarketplaceSettings(newSettings);
    marketplace.setSpaceOperatorRegistry(newRegistry);

    // All updates should succeed without reverting
    // The fact that we reach this point means all updates worked
    assertTrue(true, "Multiple admin updates should succeed");
  }

  /// @notice Test that admin functions emit correct events
  function test_admin_eventsEmitted() public {
    address newBeneficiary = makeAddr("newBeneficiary");
    address newSettings = makeAddr("newMarketplaceSettings");
    address newERC20Manager = makeAddr("newERC20Manager");
    address newERC721Manager = makeAddr("newERC721Manager");

    // Test that each admin function emits the correct event
    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.NetworkBeneficiaryUpdated(newBeneficiary);
    marketplace.setNetworkBeneficiary(newBeneficiary);

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.MarketplaceSettingsUpdated(newSettings);
    marketplace.setMarketplaceSettings(newSettings);

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.ERC20ApprovalManagerUpdated(newERC20Manager);
    marketplace.setERC20ApprovalManager(newERC20Manager);

    vm.expectEmit(true, false, false, false);
    emit MarketConfigV2.ERC721ApprovalManagerUpdated(newERC721Manager);
    marketplace.setERC721ApprovalManager(newERC721Manager);
  }

  /// @notice Test admin functions with zero addresses (should not revert at contract level)
  function test_admin_zeroAddresses() public {
    // Note: The contract itself doesn't validate zero addresses in the admin functions
    // Validation happens in the MarketConfigV2 library functions
    // These tests verify the functions can be called with zero addresses

    marketplace.setNetworkBeneficiary(address(0));
    marketplace.setMarketplaceSettings(address(0));
    marketplace.setSpaceOperatorRegistry(address(0));
    marketplace.setRoyaltyEngine(address(0));
    marketplace.setPayments(address(0));
    marketplace.setApprovedTokenRegistry(address(0));
    marketplace.setStakingSettings(address(0));
    marketplace.setStakingRegistry(address(0));
    marketplace.setERC20ApprovalManager(address(0));
    marketplace.setERC721ApprovalManager(address(0));

    // All calls should succeed at the contract level
    assertTrue(true, "Admin functions should accept zero addresses");
  }
}
