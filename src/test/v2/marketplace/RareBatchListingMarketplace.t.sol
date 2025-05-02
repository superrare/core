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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, emptyAllowListProof);
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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, emptyAllowListProof);

    // Second purchase should fail
    vm.expectRevert("buyWithMerkleProof::Token already used for this Merkle root");
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, emptyAllowListProof);
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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, emptyAllowListProof);
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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, emptyAllowListProof);
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
      marketplace.buyWithMerkleProof(address(nftContract), tokenIds[i], creator, root, proof, emptyAllowListProof);
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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, allowListProof);
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
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, allowListProof);
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

    // Set allowlist config with past timestamp
    marketplace.setAllowListConfig(root, allowListRoot, block.timestamp - 1);
    vm.stopPrank();

    // Setup: Approve the marketplace to spend buyer's tokens
    vm.startPrank(buyer);
    uint256 requiredAmount = SALE_PRICE +
      IMarketplaceSettings(_marketplaceSettings).calculateMarketplaceFee(SALE_PRICE);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);

    // Try to purchase after allowlist expired
    vm.expectRevert("buyWithMerkleProof::Allowlist period has ended");
    marketplace.buyWithMerkleProof(address(nftContract), firstTokenId, creator, root, proof, allowListProof);
    vm.stopPrank();
  }
}
