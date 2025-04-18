// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import {Test} from "forge-std/Test.sol";
import {SuperRareAuctionHouse} from "../../auctionhouse/SuperRareAuctionHouse.sol";
import {SuperRareBazaarStorage} from "../../bazaar/SuperRareBazaarStorage.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin-contracts/token/ERC721/ERC721.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

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

contract SuperRareAuctionHouseMerkleTest is Test {
  // Test contracts
  SuperRareAuctionHouse public auctionHouse;
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
    auctionHouse = new SuperRareAuctionHouse();
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
    (merkleRoot, merkleProof) = _createMerkleTree(contracts, ids);

    // Fund test users
    vm.deal(admin, 10 ether);
    vm.deal(auctionCreator, 10 ether);
    vm.deal(bidder, 10 ether);

    // Fund users with test tokens
    currencyContract.mint(bidder, 1000 * 10 ** currencyContract.decimals());
  }

  // Helper function to create a Merkle tree with multiple tokens
  function _createMerkleTree(
    address[] memory contracts,
    uint256[] memory tokenIds
  ) internal returns (bytes32 root, bytes32[] memory proof) {
    require(contracts.length == tokenIds.length, "Length mismatch");

    bytes32[] memory leaves = new bytes32[](contracts.length);

    for (uint256 i = 0; i < contracts.length; i++) {
      leaves[i] = keccak256(abi.encodePacked(contracts[i], tokenIds[i]));
    }

    root = merkle.getRoot(leaves);
    proof = merkle.getProof(leaves, 0); // Get proof for first token

    return (root, proof);
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
}
