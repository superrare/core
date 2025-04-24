// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "forge-std/Test.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";
import {ISpaceOperatorRegistry} from "rareprotocol/aux/registry/interfaces/ISpaceOperatorRegistry.sol";
import {IApprovedTokenRegistry} from "rareprotocol/aux/registry/interfaces/IApprovedTokenRegistry.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";

import {RareBatchAuctionHouse} from "../../../v2/auctionhouse/RareBatchAuctionHouse.sol";
import {IRareBatchAuctionHouse} from "../../../v2/auctionhouse/IRareBatchAuctionHouse.sol";
import {IStakingSettings} from "../../../marketplace/IStakingSettings.sol";
import {TestNFT} from "../utils/TestNft.sol";
import {TestToken} from "../utils/TestToken.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";

/// @title SuperRareAuctionHouseV2MerkleTest
/// @notice Tests for the Merkle auction functionality in SuperRareAuctionHouseV2
contract RareBatchAuctionHouseTest is Test {
  RareBatchAuctionHouse public auctionHouse;
  // Mock addresses for dependencies
  address marketplaceSettings = makeAddr("marketplaceSettings");
  address royaltyEngine = makeAddr("royaltyEngine");
  address spaceOperatorRegistry = makeAddr("spaceOperatorRegistry");
  address approvedTokenRegistry = makeAddr("approvedTokenRegistry");
  address payments = makeAddr("payments");
  address stakingRegistry = makeAddr("stakingRegistry");
  address stakingSettings = makeAddr("stakingSettings"); // New dependency in V2
  address networkBeneficiary = makeAddr("networkBeneficiary");

  // Test contracts
  TestNFT public nftContract;
  TestToken public currencyContract;
  ERC20ApprovalManager public erc20ApprovalManager;
  ERC721ApprovalManager public erc721ApprovalManager;

  // Test users
  address public admin;
  address public auctionCreator;
  address public bidder;

  // Test data
  uint256 public tokenId;
  bytes32 public merkleRoot;
  bytes32[] public merkleProof;
  IRareBatchAuctionHouse.MerkleAuctionConfig public auctionConfig;

  // Helper contract
  Merkle public merkle;

  // Constants
  uint256 public constant AUCTION_DURATION = 1 days;
  uint256 public constant STARTING_AMOUNT = 1 ether;
  uint8 public constant SPLIT_RATIO = 100;

  function setUp() public {
    // Setup test users
    admin = makeAddr("admin");
    auctionCreator = makeAddr("auctionCreator");
    bidder = makeAddr("bidder");

    // Deploy approval managers first
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();

    // Deploy other contracts
    auctionHouse = new RareBatchAuctionHouse();
    merkle = new Merkle();
    nftContract = new TestNFT();
    currencyContract = new TestToken();

    // Initialize AuctionHouse with approval managers
    auctionHouse.initialize(
      marketplaceSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      payments,
      stakingRegistry,
      stakingSettings,
      networkBeneficiary,
      address(erc20ApprovalManager),
      address(erc721ApprovalManager)
    );

    // Set up approval manager roles - admin must be the DEFAULT_ADMIN_ROLE first
    vm.startPrank(address(this)); // The test contract deploys the approval managers, so it has DEFAULT_ADMIN_ROLE
    erc20ApprovalManager.grantRole(erc20ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);
    erc721ApprovalManager.grantRole(erc721ApprovalManager.DEFAULT_ADMIN_ROLE(), admin);
    vm.stopPrank();

    // Now admin can grant OPERATOR_ROLE to the auction house
    vm.startPrank(admin);
    erc20ApprovalManager.grantRole(erc20ApprovalManager.OPERATOR_ROLE(), address(auctionHouse));
    erc721ApprovalManager.grantRole(erc721ApprovalManager.OPERATOR_ROLE(), address(auctionHouse));
    vm.stopPrank();

    // Setup test NFTs - mint multiple tokens to create a proper Merkle tree
    uint256[] memory tokenIds = nftContract.mintBatch(auctionCreator, 3);
    tokenId = tokenIds[0]; // Use the first token for our test

    // Setup auction config
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(makeAddr("splitRecipient"));
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    auctionConfig = IRareBatchAuctionHouse.MerkleAuctionConfig({
      currency: address(currencyContract),
      startingAmount: STARTING_AMOUNT,
      duration: AUCTION_DURATION,
      splitAddresses: splitAddresses,
      splitRatios: splitRatios,
      nonce: 0 // Added this field which exists in V2
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
    vm.deal(auctionCreator, 10 ether);
    vm.deal(bidder, 10 ether);

    // Fund users with test tokens
    currencyContract.mint(bidder, 1000 * 10 ** currencyContract.decimals());

    // Default Mocks
    // Mock marketplace settings
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceFeePercentage.selector),
      abi.encode(uint8(3))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMaxValue.selector),
      abi.encode(type(uint256).max)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getMarketplaceMinValue.selector),
      abi.encode(uint256(0))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, STARTING_AMOUNT),
      abi.encode((STARTING_AMOUNT * 3) / 100)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nftContract), 3),
      abi.encode(false)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(
        IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector,
        address(nftContract)
      ),
      abi.encode(15)
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.markERC721Token.selector, address(nftContract)),
      abi.encode()
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nftContract)),
      abi.encode(false)
    );

    // Mock staking settings
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, STARTING_AMOUNT),
      abi.encode((STARTING_AMOUNT * 3) / 100)
    );
    vm.mockCall(stakingSettings, abi.encodeWithSignature("calculateStakingFee(uint256)"), abi.encode(0));

    // Mock royalty engine
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyaltyView.selector),
      abi.encode(new address payable[](0), new uint256[](0))
    );
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    // Mock space operator registry
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector),
      abi.encode(true)
    );
    vm.mockCall(
      spaceOperatorRegistry,
      abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector),
      abi.encode(uint8(0))
    );

    // Mock approved token registry
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector),
      abi.encode(true)
    );

    // Mock payments
    vm.mockCall(payments, abi.encodeWithSelector(IPayments.refund.selector), abi.encode());
    vm.mockCall(payments, abi.encodeWithSelector(IPayments.payout.selector), abi.encode());

    // Mock staking registry
    vm.mockCall(
      stakingRegistry,
      abi.encodeWithSelector(bytes4(keccak256("getRewardAccumulatorAddressForUser(address)"))),
      abi.encode(address(0))
    );
  }

  // Helper function to create a Merkle tree with multiple tokens and get proof for specific token
  function _createMerkleTree(
    address[] memory contracts,
    uint256[] memory tokenIds,
    uint256 proofIndex
  ) internal view returns (bytes32 root, bytes32[] memory proof) {
    require(contracts.length == tokenIds.length, "Length mismatch");
    require(proofIndex < contracts.length, "Invalid proof index");

    bytes32[] memory leaves = new bytes32[](contracts.length);

    for (uint256 i = 0; i < contracts.length; i++) {
      leaves[i] = keccak256(abi.encodePacked(contracts[i], tokenIds[i]));
    }

    root = merkle.getRoot(leaves);
    proof = merkle.getProof(leaves, proofIndex);

    return (root, proof);
  }

  // Helper function to create a fresh Merkle tree with newly minted tokens
  function _createFreshMerkleTree(
    uint256 numTokens
  ) internal returns (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) {
    // Mint fresh tokens
    tokenIds = new uint256[](numTokens);
    address[] memory contracts = new address[](numTokens);

    for (uint256 i = 0; i < numTokens; i++) {
      tokenIds[i] = nftContract.mint(auctionCreator);
      contracts[i] = address(nftContract);

      // Approve each token
      vm.startPrank(auctionCreator);
      nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
      vm.stopPrank();
    }

    firstTokenId = tokenIds[0];

    // Create Merkle tree
    bytes32[] memory leaves = new bytes32[](numTokens);
    for (uint256 i = 0; i < numTokens; i++) {
      leaves[i] = keccak256(abi.encodePacked(contracts[i], tokenIds[i]));
    }

    root = merkle.getRoot(leaves);
    proof = merkle.getProof(leaves, 0); // Get proof for first token

    return (root, proof, tokenIds, firstTokenId);
  }

  function test_registerAuctionMerkleRoot() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the auction merkle root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );

    // Verify the root was registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Should have one root registered");
    assertEq(roots[0], root, "Registered root should match");

    // Verify the nonce was incremented
    uint256 nonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(nonce, 1, "Nonce should be 1");

    vm.stopPrank();
  }

  function test_registerAuctionMerkleRoot_invalidCurrency() public {
    // Create an invalid currency contract
    TestToken invalidCurrency = new TestToken();

    // Setup split addresses and ratios
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(makeAddr("splitRecipient"));
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = 100;

    // Mock isApprovedToken to return false for the invalid currency
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(invalidCurrency)),
      abi.encode(false)
    );

    // Try to register with invalid currency
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.expectRevert("Not approved currency");
    auctionHouse.registerAuctionMerkleRoot(
      merkleRoot,
      address(invalidCurrency),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      splitAddresses,
      splitRatios
    );
    vm.stopPrank();
  }

  function test_cancelAuctionMerkleRoot() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify root is registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Root should be registered");

    // Cancel the root
    vm.startPrank(auctionCreator);
    auctionHouse.cancelAuctionMerkleRoot(root);
    vm.stopPrank();

    // Verify root is removed
    roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 0, "Root should be removed");
  }

  function test_cancelAuctionMerkleRoot_notOwner() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , ) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Try to cancel as non-owner
    vm.startPrank(bidder);
    vm.expectRevert("cancelAuctionMerkleRoot::Not root owner");
    auctionHouse.cancelAuctionMerkleRoot(root);
    vm.stopPrank();

    // Verify root is still registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Root should still be registered");
  }

  function test_bidWithAuctionMerkleProof() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the auction merkle root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    vm.stopPrank();

    // Place bid
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Verify auction was created
    (address creator, , uint256 startTime, uint256 lengthOfAuction, , uint256 minimumBid, , , ) = auctionHouse
      .getAuctionDetails(address(nftContract), firstTokenId);
    assertEq(creator, auctionCreator, "Creator should be the one who created the Merkle root");
    assertEq(minimumBid, STARTING_AMOUNT, "Bid amount should match");
    assertEq(startTime + lengthOfAuction, block.timestamp + AUCTION_DURATION, "Auction duration should be correct");

    // Verify current bidder
    (address currentBidder, address bidCurrency, uint256 bidAmount, ) = auctionHouse.auctionBids(
      address(nftContract),
      firstTokenId
    );
    assertEq(currentBidder, bidder, "Bidder should be the current highest bidder");
    assertEq(bidAmount, STARTING_AMOUNT, "Bid amount should match");
    assertEq(bidCurrency, address(currencyContract), "Currency should match");
  }

  function test_bidWithAuctionMerkleProof_invalidProof() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory validProof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(erc20ApprovalManager), STARTING_AMOUNT);
    vm.stopPrank();

    // Create invalid proof
    bytes32[] memory invalidProof = new bytes32[](validProof.length);
    for (uint256 i = 0; i < validProof.length; i++) {
      invalidProof[i] = bytes32(uint256(validProof[i]) + 1);
    }

    // Try to place bid with invalid proof
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Invalid Merkle proof");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      invalidProof
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_replayProtection() public {
    // Setup: Register the auction root
    vm.startPrank(auctionCreator);
    // Create Merkle tree and get proof for our specific token
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );

    // Approve NFT after registering root
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount * 2); // Double for two attempts
    vm.stopPrank();

    // Place first bid
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(address(nftContract), tokenId, auctionCreator, root, STARTING_AMOUNT, proof);
    vm.stopPrank();

    // Try to place same bid again
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Token already used for this Merkle root");
    auctionHouse.bidWithAuctionMerkleProof(address(nftContract), tokenId, auctionCreator, root, STARTING_AMOUNT, proof);
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_ownershipVerification() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Transfer NFT to bidder
    vm.startPrank(auctionCreator);
    nftContract.transferFrom(auctionCreator, bidder, firstTokenId);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(erc20ApprovalManager), STARTING_AMOUNT);
    vm.stopPrank();

    // Try to place bid with wrong owner
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Not token owner");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator, // Wrong owner
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();
  }

  function test_getUserAuctionMerkleRoots() public {
    // Test with no roots
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 0, "Should have no roots initially");

    // Register multiple roots
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);

    // Create and register first root
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root1, ) = _createMerkleTree(contracts, ids, 0);
    auctionHouse.registerAuctionMerkleRoot(
      root1,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );

    // Create and register second root
    for (uint256 i = 0; i < 3; i++) {
      ids[i] = tokenId + i + 3; // Different token IDs
    }
    (bytes32 root2, ) = _createMerkleTree(contracts, ids, 0);
    auctionHouse.registerAuctionMerkleRoot(
      root2,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify both roots are returned
    roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 2, "Should have two roots");
    assertEq(roots[0], root1, "First root should match");
    assertEq(roots[1], root2, "Second root should match");
  }

  function test_getCurrentAuctionMerkleRootNonce() public {
    // Test initial nonce
    uint256 nonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, merkleRoot);
    assertEq(nonce, 0, "Initial nonce should be 0");

    // Register root and check nonce
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);

    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, ) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify nonce was incremented
    nonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(nonce, 1, "Nonce should be 1 after registration");
  }

  function test_isTokenInRoot() public {
    // Create Merkle tree with multiple tokens
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    // Test valid proof
    bool isInRoot = auctionHouse.isTokenInRoot(root, address(nftContract), tokenId, proof);
    assertTrue(isInRoot, "Token should be in root");

    // Test invalid proof
    bytes32[] memory invalidProof = new bytes32[](proof.length);
    for (uint256 i = 0; i < proof.length; i++) {
      invalidProof[i] = bytes32(uint256(proof[i]) + 1);
    }
    isInRoot = auctionHouse.isTokenInRoot(root, address(nftContract), tokenId, invalidProof);
    assertFalse(isInRoot, "Token should not be in root with invalid proof");

    // Test token not in tree
    isInRoot = auctionHouse.isTokenInRoot(root, address(nftContract), tokenId + 10, proof);
    assertFalse(isInRoot, "Token should not be in root");
  }

  function test_dualNonceSystem_basicFlow() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Setup: Register initial auction root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify initial nonces
    uint256 rootNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(rootNonce, 1, "Initial root nonce should be 1");

    // Mock platform commission
    vm.mockCall(
      address(spaceOperatorRegistry),
      abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector, auctionCreator),
      abi.encode(uint8(0))
    );
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.hasERC721TokenSold.selector, address(nftContract), 6),
      abi.encode(false)
    );
    // Setup bidder with enough allowance for both bids including fees
    vm.startPrank(bidder);
    uint256 marketplaceFee = IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    uint256 totalRequiredAmount = (STARTING_AMOUNT + marketplaceFee) * 2; // Enough for two bids including fees
    currencyContract.approve(address(erc20ApprovalManager), totalRequiredAmount);
    vm.stopPrank();

    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Verify token nonce was incremented
    uint256 tokenNonce = auctionHouse.getTokenAuctionNonce(auctionCreator, root, address(nftContract), firstTokenId);
    assertEq(tokenNonce, 1, "Token nonce should be 1 after sale");

    // Settle the auction before trying to sell again
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), firstTokenId);

    // Approve token for new owner (bidder)
    vm.startPrank(bidder);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    // Try to sell same token again - should fail
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Token already used for this Merkle root");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Create fresh tokens and Merkle tree for reconfiguration
    (
      bytes32 newRoot,
      bytes32[] memory newProof,
      uint256[] memory newTokenIds,
      uint256 newFirstTokenId
    ) = _createFreshMerkleTree(3);

    // Reconfigure auction with new root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      newRoot,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify root nonce incremented
    rootNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, newRoot);
    assertEq(rootNonce, 1, "New root nonce should be 1");

    // Now new token can be sold under new configuration
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      newFirstTokenId,
      auctionCreator,
      newRoot,
      STARTING_AMOUNT,
      newProof
    );
    vm.stopPrank();

    // Settle the auction for newFirstTokenId
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), newFirstTokenId);

    // Verify token nonce updated
    tokenNonce = auctionHouse.getTokenAuctionNonce(auctionCreator, newRoot, address(nftContract), newFirstTokenId);
    assertEq(tokenNonce, 1, "New token nonce should be 1 after sale under new root");

    // 5. Simulate Token Return to Creator
    vm.startPrank(bidder);
    // Need to approve the token for transfer
    nftContract.approve(auctionCreator, firstTokenId);
    nftContract.transferFrom(bidder, auctionCreator, firstTokenId);
    vm.stopPrank();
    assertEq(nftContract.ownerOf(firstTokenId), auctionCreator, "Token should be back with creator");
  }

  function test_dualNonceSystem_multipleTokens() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup bidder
    vm.startPrank(bidder);
    currencyContract.approve(address(erc20ApprovalManager), STARTING_AMOUNT * 3); // Enough for three bids
    vm.stopPrank();

    // Bid on first token
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Create new Merkle tree for second token
    (
      bytes32 newRoot,
      bytes32[] memory newProof,
      uint256[] memory newTokenIds,
      uint256 newFirstTokenId
    ) = _createFreshMerkleTree(3);

    // Register new root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      newRoot,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Bid on first token of new tree
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      newFirstTokenId,
      auctionCreator,
      newRoot,
      STARTING_AMOUNT,
      newProof
    );
    vm.stopPrank();

    // Verify nonces
    uint256 token1Nonce = auctionHouse.getTokenAuctionNonce(auctionCreator, root, address(nftContract), firstTokenId);
    uint256 token2Nonce = auctionHouse.getTokenAuctionNonce(
      auctionCreator,
      newRoot,
      address(nftContract),
      newFirstTokenId
    );
    assertEq(token1Nonce, 1, "First token nonce should be 1");
    assertEq(token2Nonce, 1, "Second token nonce should be 1");
  }

  function test_dualNonceSystem_reconfiguration() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, uint256[] memory tokenIds, uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register initial root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify initial nonce
    uint256 rootNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(rootNonce, 1, "Initial root nonce should be 1");

    // Mock platform commission
    vm.mockCall(
      address(spaceOperatorRegistry),
      abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector, auctionCreator),
      abi.encode(uint8(0))
    );

    vm.startPrank(bidder);
    uint256 marketplaceFee = IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    uint256 totalRequiredAmount = (STARTING_AMOUNT + marketplaceFee) * 2; // Enough for two bids including fees
    currencyContract.approve(address(erc20ApprovalManager), totalRequiredAmount);
    vm.stopPrank();

    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Settle the auction so the bidder gets the token
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), firstTokenId);

    // Transfer token back to auctionCreator
    vm.startPrank(bidder);
    nftContract.approve(auctionCreator, firstTokenId);
    nftContract.transferFrom(bidder, auctionCreator, firstTokenId);
    vm.stopPrank();

    // Create new tokens and tree for reconfiguration
    (
      bytes32 newRoot,
      bytes32[] memory newProof,
      uint256[] memory newTokenIds,
      uint256 newFirstTokenId
    ) = _createFreshMerkleTree(3);

    // Register new root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      newRoot,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify nonces
    rootNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, newRoot);
    uint256 token1Nonce = auctionHouse.getTokenAuctionNonce(auctionCreator, root, address(nftContract), firstTokenId);
    uint256 token2Nonce = auctionHouse.getTokenAuctionNonce(
      auctionCreator,
      newRoot,
      address(nftContract),
      newFirstTokenId
    );

    assertEq(rootNonce, 1, "New root nonce should be 1");
    assertEq(token1Nonce, 1, "First token nonce should be 1");
    assertEq(token2Nonce, 0, "Second token nonce should be 0 (not used yet)");

    // Bid on new token
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      newFirstTokenId,
      auctionCreator,
      newRoot,
      STARTING_AMOUNT,
      newProof
    );
    vm.stopPrank();

    // Settle the auction for newFirstTokenId
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), newFirstTokenId);

    // Verify final nonces
    token2Nonce = auctionHouse.getTokenAuctionNonce(auctionCreator, newRoot, address(nftContract), newFirstTokenId);
    assertEq(token2Nonce, 1, "Second token nonce should be 1 after bid");

    // Verify token nonce was updated correctly
    // The token's nonce for this root was effectively reset/deleted upon cancellation.
    // The bid succeeds because the new root config nonce (2) is greater than the token's (now implicit 0).
    // The bid sets the token's nonce to 1.
    uint256 finalTokenNonce = auctionHouse.getTokenAuctionNonce(
      auctionCreator,
      root,
      address(nftContract),
      firstTokenId
    );
    assertEq(finalTokenNonce, 1, "Token nonce should be 1 after successful bid under reconfigured root");
  }

  function test_bidWithAuctionMerkleProof_ETHPayment() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the auction merkle root with ETH as currency
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(0), // ETH
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Mint ETH for the bidder
    vm.deal(bidder, STARTING_AMOUNT * 2); // Give bidder some ETH

    // Calculate required amount including fee
    uint256 marketplaceFee = IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    uint256 requiredAmount = STARTING_AMOUNT + marketplaceFee;
    (, , , , , , bytes32 auctionType, , ) = auctionHouse.getAuctionDetails(address(nftContract), firstTokenId);
    assertEq(auctionType, auctionHouse.NO_AUCTION(), "Auction type should be NO_AUCTION");
    // Place bid with ETH
    vm.startPrank(bidder);
    currencyContract.increaseAllowance(address(erc20ApprovalManager), requiredAmount);
    auctionHouse.bidWithAuctionMerkleProof{value: requiredAmount}(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Verify auction was created
    (address creator, , uint256 startTime, uint256 lengthOfAuction, , uint256 minimumBid, , , ) = auctionHouse
      .getAuctionDetails(address(nftContract), firstTokenId);
    assertEq(creator, auctionCreator, "Creator should be the one who created the Merkle root");
    assertEq(minimumBid, STARTING_AMOUNT, "Bid amount should match");
    assertEq(startTime + lengthOfAuction, block.timestamp + AUCTION_DURATION, "Auction duration should be correct");

    // Verify current bidder and ETH bid
    (address currentBidder, address bidCurrency, uint256 bidAmount, ) = auctionHouse.auctionBids(
      address(nftContract),
      firstTokenId
    );
    assertEq(currentBidder, bidder, "Bidder should be the current highest bidder");
    assertEq(bidAmount, STARTING_AMOUNT, "Bid amount should match");
    assertEq(bidCurrency, address(0), "Currency should be ETH");

    // Verify contract ETH balance increased
    assertEq(address(auctionHouse).balance, requiredAmount, "AuctionHouse ETH balance incorrect");
  }

  function test_bidWithAuctionMerkleProof_ETH_InsufficientBalance() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the auction merkle root with ETH as currency
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(0), // ETH
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Mint ETH for the bidder, but less than required
    vm.deal(bidder, STARTING_AMOUNT / 2);

    // Calculate required amount including fee
    uint256 marketplaceFee = IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    uint256 requiredAmount = STARTING_AMOUNT + marketplaceFee;

    // Try to place bid with insufficient ETH
    vm.startPrank(bidder);
    vm.expectRevert("not enough eth sent");
    auctionHouse.bidWithAuctionMerkleProof{value: STARTING_AMOUNT / 2}(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_NonExistentTokenId() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the auction merkle root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    vm.stopPrank();

    uint256 nonExistentTokenId = 9999;

    // Try to place bid with non-existent token ID
    vm.startPrank(bidder);
    // Note: The Merkle proof validation happens first, so that's the expected revert.
    vm.expectRevert("bidWithAuctionMerkleProof::Invalid Merkle proof");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      nonExistentTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof // Using proof for firstTokenId, which won't match nonExistentTokenId
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_MalformedProof() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory validProof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    vm.stopPrank();

    // Create malformed proof (modify one element)
    bytes32[] memory malformedProof = new bytes32[](validProof.length);
    for (uint256 i = 0; i < validProof.length; i++) {
      malformedProof[i] = validProof[i];
    }
    if (malformedProof.length > 0) {
      malformedProof[0] = bytes32(uint256(malformedProof[0]) + 1);
    }

    // Try to place bid with malformed proof
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Invalid Merkle proof");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      malformedProof
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_EmptyProof() public {
    // Create fresh tokens and Merkle tree
    (bytes32 root, , , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Register the auction merkle root
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    vm.stopPrank();

    // Create empty proof
    bytes32[] memory emptyProof = new bytes32[](0);

    // Try to place bid with empty proof
    vm.startPrank(bidder);
    vm.expectRevert("bidWithAuctionMerkleProof::Invalid Merkle proof");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      emptyProof
    );
    vm.stopPrank();
  }

  function test_gas_bidWithLargeMerkleTree_ETH() public {
    uint256 numTokens = 1000;

    // --- Create Large Merkle Tree ---
    uint256[] memory tokenIds = new uint256[](numTokens);
    address[] memory contracts = new address[](numTokens);
    bytes32[] memory leaves = new bytes32[](numTokens);

    vm.startPrank(auctionCreator);
    for (uint256 i = 0; i < numTokens; i++) {
      tokenIds[i] = nftContract.mint(auctionCreator);
      contracts[i] = address(nftContract);
      leaves[i] = keccak256(abi.encodePacked(contracts[i], tokenIds[i]));
    }
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    bytes32 root = merkle.getRoot(leaves);
    // Get proof for the middle token (index 500)
    uint256 targetTokenIndex = numTokens / 2;
    uint256 targetTokenId = tokenIds[targetTokenIndex];
    bytes32[] memory proof = merkle.getProof(leaves, targetTokenIndex);
    // --------------------------------

    // Register the auction merkle root with ETH as currency
    vm.startPrank(auctionCreator);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(0), // ETH
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Calculate required amount including fee
    uint256 marketplaceFee = IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    uint256 requiredAmount = STARTING_AMOUNT + marketplaceFee;

    // Mint ETH for the bidder
    vm.deal(bidder, requiredAmount * 2); // Give bidder enough ETH

    // Place bid with ETH for the target token
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof{value: requiredAmount}(
      address(nftContract),
      targetTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Verify auction was created for the target token
    (address creator, , , , , uint256 minimumBid, , , ) = auctionHouse.getAuctionDetails(
      address(nftContract),
      targetTokenId
    );
    assertEq(creator, auctionCreator, "Creator should be the one who created the Merkle root");
    assertEq(minimumBid, STARTING_AMOUNT, "Bid amount should match");

    // Verify current bidder and ETH bid for the target token
    (address currentBidder, address bidCurrency, uint256 bidAmount, ) = auctionHouse.auctionBids(
      address(nftContract),
      targetTokenId
    );
    assertEq(currentBidder, bidder, "Bidder should be the current highest bidder");
    assertEq(bidAmount, STARTING_AMOUNT, "Bid amount should match");
    assertEq(bidCurrency, address(0), "Currency should be ETH");

    // Verify contract ETH balance increased
    assertEq(address(auctionHouse).balance, requiredAmount, "AuctionHouse ETH balance incorrect");
  }

  function test_rootManagement_reconfigureAfterFailedAuction() public {
    // 1. Setup: Create fresh tokens and Merkle tree
    (bytes32 root, bytes32[] memory proof, , uint256 firstTokenId) = _createFreshMerkleTree(3);

    // Approve the first token for the initial registration
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    vm.stopPrank();

    // 2. Register the initial Merkle root
    vm.startPrank(auctionCreator);
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify initial registration
    uint256 initialNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(initialNonce, 1, "Initial root nonce should be 1");
    assertTrue(auctionHouse.getUserAuctionMerkleRoots(auctionCreator)[0] == root, "Root should be registered");

    // 3. Simulate Auction: Place initial bid to create auction state
    vm.startPrank(bidder);
    uint256 requiredAmount = STARTING_AMOUNT +
      IMarketplaceSettings(marketplaceSettings).calculateMarketplaceFee(STARTING_AMOUNT);
    currencyContract.approve(address(erc20ApprovalManager), requiredAmount);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId,
      auctionCreator,
      root,
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // 4. Simulate Auction End and Settlement (Token goes to bidder)
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), firstTokenId);
    assertEq(nftContract.ownerOf(firstTokenId), bidder, "Token should be with bidder after settlement");

    // 5. Simulate Token Return to Creator
    vm.startPrank(bidder);
    // Need to approve the token for transfer
    nftContract.approve(auctionCreator, firstTokenId);
    nftContract.transferFrom(bidder, auctionCreator, firstTokenId);
    vm.stopPrank();
    assertEq(nftContract.ownerOf(firstTokenId), auctionCreator, "Token should be back with creator");

    // 6. Creator Cancels the Root
    vm.startPrank(auctionCreator);
    auctionHouse.cancelAuctionMerkleRoot(root);
    vm.stopPrank();

    // Verify cancellation
    bytes32[] memory rootsAfterCancel = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(rootsAfterCancel.length, 0, "Root should be cancelled");
    // Check config is zeroed out
    IRareBatchAuctionHouse.MerkleAuctionConfig memory config = auctionHouse.getMerkleAuctionConfig(
      auctionCreator,
      root
    );
    assertEq(config.currency, address(0), "Config currency should be zeroed out after cancel");
    assertEq(config.startingAmount, 0, "Config startingAmount should be zeroed out after cancel");

    // 7. Creator Reconfigures the *Same* Root
    vm.startPrank(auctionCreator);
    // Approve the token again for the new registration/auction
    nftContract.setApprovalForAll(address(erc721ApprovalManager), true);
    auctionHouse.registerAuctionMerkleRoot(
      root, // Using the same root
      address(currencyContract),
      STARTING_AMOUNT + 1 ether, // Change config slightly
      AUCTION_DURATION,
      auctionConfig.splitAddresses,
      auctionConfig.splitRatios
    );
    vm.stopPrank();

    // Verify re-registration and nonce increment
    uint256 newNonce = auctionHouse.getCreatorAuctionMerkleRootNonce(auctionCreator, root);
    assertEq(newNonce, 2, "Nonce should be 2 after re-registration");
    bytes32[] memory rootsAfterReconfigure = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(rootsAfterReconfigure.length, 1, "Root should be registered again");
    assertEq(rootsAfterReconfigure[0], root, "Re-registered root should match");

    // 8. Attempt Bid under New Nonce Configuration
    vm.startPrank(bidder);
    uint256 newStartingAmount = STARTING_AMOUNT + 1 ether;
    uint256 newMarketplaceFee = (newStartingAmount * 3) / 100;

    // Mock marketplace fee calculation for new amount
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, newStartingAmount),
      abi.encode(newMarketplaceFee)
    );

    // Mock staking settings
    vm.mockCall(
      stakingSettings,
      abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, newStartingAmount),
      abi.encode(newMarketplaceFee)
    );

    uint256 newRequiredAmount = newStartingAmount + newMarketplaceFee;
    // Ensure enough allowance for the new amount
    currencyContract.approve(address(erc20ApprovalManager), newRequiredAmount);
    vm.stopPrank();

    // Place bid using the original proof but against the reconfigured root (nonce 2)
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      firstTokenId, // Same token that was returned
      auctionCreator,
      root,
      newStartingAmount,
      proof // Original proof is still valid for the token inclusion in the root
    );
    vm.stopPrank();

    // Verify auction was created successfully under the new nonce
    (
      address creator,
      ,
      uint256 startTime,
      uint256 lengthOfAuction,
      address auctionCurrency,
      uint256 minimumBid,
      ,
      ,

    ) = auctionHouse.getAuctionDetails(address(nftContract), firstTokenId);
    assertEq(creator, auctionCreator, "Creator should match");
    assertEq(minimumBid, newStartingAmount, "Minimum bid should match new config");
    assertEq(auctionCurrency, address(currencyContract), "Currency should match new config");

    // Verify token nonce was updated correctly
    // The token's nonce for this root was effectively reset/deleted upon cancellation.
    // The bid succeeds because the new root config nonce (2) is greater than the token's (now implicit 0).
    // The bid sets the token's nonce to 1.
    uint256 finalTokenNonce = auctionHouse.getTokenAuctionNonce(
      auctionCreator,
      root,
      address(nftContract),
      firstTokenId
    );
    assertEq(finalTokenNonce, 2, "Token nonce should be 1 after successful bid under reconfigured root");

    // 9. Complete the sale by settling the auction
    vm.warp(block.timestamp + AUCTION_DURATION + 1);
    auctionHouse.settleAuction(address(nftContract), firstTokenId);

    // Verify the token is transferred to the bidder
    assertEq(nftContract.ownerOf(firstTokenId), bidder, "Token should be with bidder after settlement");
  }
}
