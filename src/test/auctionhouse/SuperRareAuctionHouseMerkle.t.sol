// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "forge-std/Test.sol";
import {SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";
import {SuperRareBazaarStorage} from "../../bazaar/SuperRareBazaarStorage.sol";
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

contract TestNFT is ERC721 {
  uint256 private _nextTokenId;

  constructor() ERC721("Test NFT", "TNFT") {}

  function mint(address to) public returns (uint256) {
    uint256 tokenId = _nextTokenId++;
    _mint(to, tokenId);
    return tokenId;
  }

  function mintBatch(address to, uint256 count) public returns (uint256[] memory) {
    uint256[] memory tokenIds = new uint256[](count);
    for (uint256 i = 0; i < count; i++) {
      tokenIds[i] = mint(to);
    }
    return tokenIds;
  }
}

contract TestToken is ERC20 {
  constructor() ERC20("Test Token", "TT") {
    _mint(msg.sender, 1000000 * 10 ** decimals());
  }

  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }
}

contract TestAuctionHouse is SuperRareAuctionHouse {
  function initialize(
    address _marketplaceSettings,
    address _royaltyEngine,
    address _spaceOperatorRegistry,
    address _approvedTokenRegistry,
    address _payments,
    address _stakingRegistry,
    address _networkBeneficiary
  ) public initializer {
    // Initialize the auction house
    marketplaceSettings = IMarketplaceSettings(_marketplaceSettings);
    royaltyEngine = IRoyaltyEngineV1(_royaltyEngine);
    spaceOperatorRegistry = ISpaceOperatorRegistry(_spaceOperatorRegistry);
    approvedTokenRegistry = IApprovedTokenRegistry(_approvedTokenRegistry);
    payments = IPayments(_payments);
    stakingRegistry = _stakingRegistry;
    networkBeneficiary = _networkBeneficiary;

    // Set auction parameters
    minimumBidIncreasePercentage = 10;
    maxAuctionLength = 7 days;
    auctionLengthExtension = 15 minutes;
    offerCancelationDelay = 5 minutes;

    // Initialize Ownable and ReentrancyGuard
    __Ownable_init();
    __ReentrancyGuard_init();
  }
}

contract SuperRareAuctionHouseMerkleTest is Test {
  // Mock addresses for dependencies
  address marketplaceSettings = makeAddr("marketplaceSettings");
  address royaltyEngine = makeAddr("royaltyEngine");
  address spaceOperatorRegistry = makeAddr("spaceOperatorRegistry");
  address approvedTokenRegistry = makeAddr("approvedTokenRegistry");
  address payments = makeAddr("payments");
  address stakingRegistry = makeAddr("stakingRegistry");
  address networkBeneficiary = makeAddr("networkBeneficiary");

  // Test contracts
  TestAuctionHouse public auctionHouse;
  TestNFT public nftContract;
  TestToken public currencyContract;

  // Test users
  address public admin;
  address public auctionCreator;
  address public bidder;

  // Test data
  uint256 public tokenId;
  bytes32 public merkleRoot;
  bytes32[] public merkleProof;
  SuperRareBazaarStorage.MerkleAuctionConfig public auctionConfig;

  // Helper contract
  Merkle public merkle;

  // Constants
  uint256 public constant AUCTION_DURATION = 1 days;
  uint256 public constant STARTING_AMOUNT = 1 ether;
  uint8 public constant SPLIT_RATIO = 10;

  function setUp() public {
    // Setup test users
    admin = makeAddr("admin");
    auctionCreator = makeAddr("auctionCreator");
    bidder = makeAddr("bidder");

    // Deploy contracts
    auctionHouse = new TestAuctionHouse();
    auctionHouse.initialize(
      marketplaceSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      payments,
      stakingRegistry,
      networkBeneficiary
    );
    merkle = new Merkle();
    nftContract = new TestNFT();
    currencyContract = new TestToken();

    // Setup test NFTs - mint multiple tokens to create a proper Merkle tree
    uint256[] memory tokenIds = nftContract.mintBatch(auctionCreator, 3);
    tokenId = tokenIds[0]; // Use the first token for our test

    // Setup auction config
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(makeAddr("splitRecipient"));
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = SPLIT_RATIO;

    auctionConfig = SuperRareBazaarStorage.MerkleAuctionConfig({
      currency: address(currencyContract),
      startingAmount: STARTING_AMOUNT,
      duration: AUCTION_DURATION,
      splitAddresses: splitAddresses,
      splitRatios: splitRatios
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
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, uint256(100)),
      abi.encode(uint256(3))
    );

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

    // Mock approved token registry
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector),
      abi.encode(true)
    );

    // Mock payments
    vm.mockCall(payments, abi.encodeWithSelector(IPayments.refund.selector), abi.encode());
    vm.mockCall(payments, abi.encodeWithSelector(IPayments.payout.selector), abi.encode());
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

  // Helper function to get proof for a specific token
  function _getProofForToken(
    address contractAddress,
    uint256 targetTokenId,
    uint256 proofIndex
  ) internal view returns (bytes32[] memory) {
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = contractAddress;
      ids[i] = targetTokenId + i;
    }
    (, bytes32[] memory proof) = _createMerkleTree(contracts, ids, proofIndex);
    return proof;
  }

  function test_registerAuctionMerkleRoot() public {
    // Start acting as the auction creator
    vm.startPrank(auctionCreator);

    // Approve the NFT for the auction house
    nftContract.approve(address(auctionHouse), tokenId);

    // Register the auction merkle root
    auctionHouse.registerAuctionMerkleRoot(merkleRoot, auctionConfig);

    // Verify the root was registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Should have one root registered");
    assertEq(roots[0], merkleRoot, "Registered root should match");

    // Verify the nonce was incremented
    uint256 nonce = auctionHouse.getCurrentAuctionMerkleRootNonce(auctionCreator, merkleRoot);
    assertEq(nonce, 1, "Nonce should be 1");

    vm.stopPrank();
  }

  function test_registerAuctionMerkleRoot_invalidCurrency() public {
    // Create an invalid currency contract
    TestToken invalidCurrency = new TestToken();

    // Setup auction config with invalid currency
    address payable[] memory splitAddresses = new address payable[](1);
    splitAddresses[0] = payable(makeAddr("splitRecipient"));
    uint8[] memory splitRatios = new uint8[](1);
    splitRatios[0] = SPLIT_RATIO;

    SuperRareBazaarStorage.MerkleAuctionConfig memory invalidConfig = SuperRareBazaarStorage.MerkleAuctionConfig({
      currency: address(invalidCurrency),
      startingAmount: STARTING_AMOUNT,
      duration: AUCTION_DURATION,
      splitAddresses: splitAddresses,
      splitRatios: splitRatios
    });

    // Mock isApprovedToken to return false for the invalid currency
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(invalidCurrency)),
      abi.encode(false)
    );

    // Try to register with invalid currency
    vm.startPrank(auctionCreator);
    vm.expectRevert("Not approved currency");
    auctionHouse.registerAuctionMerkleRoot(merkleRoot, invalidConfig);
    vm.stopPrank();
  }

  function test_cancelAuctionMerkleRoot() public {
    // First register a root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);
    auctionHouse.registerAuctionMerkleRoot(merkleRoot, auctionConfig);
    vm.stopPrank();

    // Verify root is registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Root should be registered");

    // Cancel the root
    vm.startPrank(auctionCreator);
    auctionHouse.cancelAuctionMerkleRoot(merkleRoot);
    vm.stopPrank();

    // Verify root is removed
    roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 0, "Root should be removed");
  }

  function test_cancelAuctionMerkleRoot_notOwner() public {
    // First register a root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);
    auctionHouse.registerAuctionMerkleRoot(merkleRoot, auctionConfig);
    vm.stopPrank();

    // Try to cancel as non-owner
    vm.startPrank(bidder);
    vm.expectRevert("Not root owner");
    auctionHouse.cancelAuctionMerkleRoot(merkleRoot);
    vm.stopPrank();

    // Verify root is still registered
    bytes32[] memory roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 1, "Root should still be registered");
  }

  function test_bidWithAuctionMerkleProof() public {
    // Setup: Register the auction root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);

    // Create Merkle tree and get proof for our specific token
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(root, auctionConfig);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(auctionHouse), STARTING_AMOUNT);
    vm.stopPrank();

    // Place bid
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      tokenId,
      auctionCreator,
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Verify auction was created
    (
      address creator,
      uint256 creationBlock,
      uint256 startTime,
      uint256 lengthOfAuction,
      address currencyAddress,
      uint256 minimumBid,
      bytes32 auctionType,
      address payable[] memory splitRecipients,
      uint8[] memory splitRatios
    ) = auctionHouse.getAuctionDetails(address(nftContract), tokenId);
    assertEq(creator, bidder, "Bidder should be highest bidder");
    assertEq(minimumBid, STARTING_AMOUNT, "Bid amount should match");
    assertEq(startTime + lengthOfAuction, block.timestamp + AUCTION_DURATION, "Auction duration should be correct");
  }

  function test_bidWithAuctionMerkleProof_invalidProof() public {
    // Setup: Register the auction root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);

    // Create Merkle tree and get proof for our specific token
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory validProof) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(root, auctionConfig);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(auctionHouse), STARTING_AMOUNT);
    vm.stopPrank();

    // Create invalid proof
    bytes32[] memory invalidProof = new bytes32[](validProof.length);
    for (uint256 i = 0; i < validProof.length; i++) {
      invalidProof[i] = bytes32(uint256(validProof[i]) + 1);
    }

    // Try to place bid with invalid proof
    vm.startPrank(bidder);
    vm.expectRevert("Invalid merkle proof");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      tokenId,
      auctionCreator,
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      invalidProof
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_replayProtection() public {
    // Setup: Register the auction root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);

    // Create Merkle tree and get proof for our specific token
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(root, auctionConfig);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(auctionHouse), STARTING_AMOUNT * 2);
    vm.stopPrank();

    // Place first bid
    vm.startPrank(bidder);
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      tokenId,
      auctionCreator,
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();

    // Try to place same bid again
    vm.startPrank(bidder);
    vm.expectRevert("Proof already used");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      tokenId,
      auctionCreator,
      root,
      address(currencyContract),
      STARTING_AMOUNT,
      proof
    );
    vm.stopPrank();
  }

  function test_bidWithAuctionMerkleProof_ownershipVerification() public {
    // Setup: Register the auction root
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);

    // Create Merkle tree and get proof for our specific token
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, bytes32[] memory proof) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(root, auctionConfig);
    vm.stopPrank();

    // Transfer NFT to someone else
    vm.startPrank(auctionCreator);
    nftContract.transferFrom(auctionCreator, bidder, tokenId);
    vm.stopPrank();

    // Setup: Approve the auction house to spend bidder's tokens
    vm.startPrank(bidder);
    currencyContract.approve(address(auctionHouse), STARTING_AMOUNT);
    vm.stopPrank();

    // Try to place bid with wrong owner
    vm.startPrank(bidder);
    vm.expectRevert("Not token owner");
    auctionHouse.bidWithAuctionMerkleProof(
      address(nftContract),
      tokenId,
      auctionCreator, // Wrong owner
      root,
      address(currencyContract),
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
    nftContract.approve(address(auctionHouse), tokenId);

    // Create and register first root
    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root1, ) = _createMerkleTree(contracts, ids, 0);
    auctionHouse.registerAuctionMerkleRoot(root1, auctionConfig);

    // Create and register second root
    for (uint256 i = 0; i < 3; i++) {
      ids[i] = tokenId + i + 3; // Different token IDs
    }
    (bytes32 root2, ) = _createMerkleTree(contracts, ids, 0);
    auctionHouse.registerAuctionMerkleRoot(root2, auctionConfig);
    vm.stopPrank();

    // Verify both roots are returned
    roots = auctionHouse.getUserAuctionMerkleRoots(auctionCreator);
    assertEq(roots.length, 2, "Should have two roots");
    assertEq(roots[0], root1, "First root should match");
    assertEq(roots[1], root2, "Second root should match");
  }

  function test_getCurrentAuctionMerkleRootNonce() public {
    // Test initial nonce
    uint256 nonce = auctionHouse.getCurrentAuctionMerkleRootNonce(auctionCreator, merkleRoot);
    assertEq(nonce, 0, "Initial nonce should be 0");

    // Register root and check nonce
    vm.startPrank(auctionCreator);
    nftContract.approve(address(auctionHouse), tokenId);

    address[] memory contracts = new address[](3);
    uint256[] memory ids = new uint256[](3);
    for (uint256 i = 0; i < 3; i++) {
      contracts[i] = address(nftContract);
      ids[i] = tokenId + i;
    }
    (bytes32 root, ) = _createMerkleTree(contracts, ids, 0);

    auctionHouse.registerAuctionMerkleRoot(root, auctionConfig);
    vm.stopPrank();

    // Verify nonce was incremented
    nonce = auctionHouse.getCurrentAuctionMerkleRootNonce(auctionCreator, root);
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
}
