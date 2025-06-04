// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {SovereignNFTV2} from "../../../../../v2/token/ERC721/sovereign/SovereignNFTV2.sol";
import {SovereignNFTContractFactoryV2} from "../../../../../v2/token/ERC721/sovereign/SovereignNFTContractFactoryV2.sol";

contract SovereignNFTV2Test is Test {
  // Events to test
  event TokenURIUpdated(uint256 indexed tokenId, string newURI);
  event BatchBaseURIUpdated(uint256 indexed batchIndex, string newBaseURI);
  event TokenURIsLocked();
  event ContractDisabled(address indexed user);
  event ConsecutiveTransfer(
    uint256 indexed fromTokenId,
    uint256 toTokenId,
    address indexed fromAddress,
    address indexed toAddress
  );

  // Constants for contract types
  bytes32 public constant SOVEREIGN_NFT = keccak256("SOVEREIGN_NFT");
  bytes32 public constant ROYALTY_GUARD = keccak256("ROYALTY_GUARD");
  bytes32 public constant ROYALTY_GUARD_DEADMAN = keccak256("ROYALTY_GUARD_DEADMAN");

  // Contracts
  SovereignNFTV2 public sovereignNFT;
  SovereignNFTContractFactoryV2 public factory;
  SovereignNFTV2 public deployedNFT;

  // Test addresses
  address public constant CREATOR = address(0x1);
  address public constant USER1 = address(0x2);
  address public constant USER2 = address(0x3);
  address public constant ROYALTY_RECEIVER = address(0x4);

  // Test values
  string public constant NAME = "Sovereign NFT";
  string public constant SYMBOL = "SNFT";
  uint256 public constant MAX_TOKENS = 1000;
  string public constant TOKEN_URI = "ipfs://QmExample";
  string public constant BATCH_BASE_URI = "https://api.example.com/metadata";

  function setUp() public {
    // Deploy implementation contract
    vm.startPrank(CREATOR);
    sovereignNFT = new SovereignNFTV2();

    // Deploy factory
    factory = new SovereignNFTContractFactoryV2();

    // Create a sovereign NFT contract through the factory
    factory.setSovereignNFT(address(sovereignNFT));
    address nftAddr = factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS, SOVEREIGN_NFT);
    deployedNFT = SovereignNFTV2(nftAddr);
    vm.stopPrank();
  }

  function test_InitialState() public {
    assertEq(deployedNFT.name(), NAME);
    assertEq(deployedNFT.symbol(), SYMBOL);
    assertEq(deployedNFT.owner(), CREATOR);
    assertEq(deployedNFT.maxTokens(), MAX_TOKENS);
    assertFalse(deployedNFT.disabled());
    assertFalse(deployedNFT.tokenURIsLocked());
    assertEq(deployedNFT.totalSupply(), 0);
  }

  function test_AddNewToken() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Verify token was created correctly
    assertEq(deployedNFT.totalSupply(), 1);
    assertEq(deployedNFT.ownerOf(1), CREATOR);
    assertEq(deployedNFT.tokenURI(1), TOKEN_URI);

    vm.stopPrank();
  }

  function test_MintTo() public {
    vm.startPrank(CREATOR);

    // Mint a token to USER1
    deployedNFT.mintTo(TOKEN_URI, USER1, ROYALTY_RECEIVER);

    // Verify token was minted correctly
    assertEq(deployedNFT.totalSupply(), 1);
    assertEq(deployedNFT.ownerOf(1), USER1);
    assertEq(deployedNFT.tokenURI(1), TOKEN_URI);

    vm.stopPrank();
  }

  function test_BatchMint() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    vm.expectEmit(true, true, true, true);
    emit ConsecutiveTransfer(1, numTokens, address(0), CREATOR);
    deployedNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Verify tokens were minted correctly
    assertEq(deployedNFT.totalSupply(), numTokens);

    // Check ownership and URIs
    for (uint256 i = 1; i <= numTokens; i++) {
      assertEq(deployedNFT.ownerOf(i), CREATOR);
      assertEq(deployedNFT.tokenURI(i), string(abi.encodePacked(BATCH_BASE_URI, "/", vm.toString(i), ".json")));
    }

    vm.stopPrank();
  }

  function test_UpdateTokenURI() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Update the token URI
    string memory newURI = "ipfs://QmUpdated";
    vm.expectEmit(true, true, true, true);
    emit TokenURIUpdated(1, newURI);
    deployedNFT.updateTokenURI(1, newURI);

    // Verify URI was updated
    assertEq(deployedNFT.tokenURI(1), newURI);

    vm.stopPrank();
  }

  function test_UpdateBatchBaseURI() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    deployedNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Update the batch base URI
    string memory newBaseURI = "https://api.updated.com/metadata";
    vm.expectEmit(true, true, true, true);
    emit BatchBaseURIUpdated(0, newBaseURI);
    deployedNFT.updateBatchBaseURI(0, newBaseURI);

    // Verify base URI was updated for all tokens in the batch
    for (uint256 i = 1; i <= numTokens; i++) {
      assertEq(deployedNFT.tokenURI(i), string(abi.encodePacked(newBaseURI, "/", vm.toString(i), ".json")));
    }

    vm.stopPrank();
  }

  function test_LockTokenURIs() public {
    vm.startPrank(CREATOR);

    // Lock token URIs
    vm.expectEmit(true, true, true, true);
    emit TokenURIsLocked();
    deployedNFT.lockTokenURIs();

    // Verify URIs are locked
    assertTrue(deployedNFT.tokenURIsLocked());
    assertTrue(deployedNFT.areTokenURIsLocked());

    vm.stopPrank();
  }

  function test_DisableContract() public {
    vm.startPrank(CREATOR);

    // Disable the contract
    vm.expectEmit(true, true, true, true);
    emit ContractDisabled(CREATOR);
    deployedNFT.disableContract();

    // Verify contract is disabled
    assertTrue(deployedNFT.disabled());

    vm.stopPrank();
  }

  function test_Burn() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Burn the token
    deployedNFT.burn(1);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    deployedNFT.ownerOf(1);

    vm.stopPrank();
  }

  function test_Transfer() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Transfer token to USER1
    deployedNFT.transferFrom(CREATOR, USER1, 1);

    // Verify transfer worked
    assertEq(deployedNFT.ownerOf(1), USER1);

    vm.stopPrank();
  }

  function test_RoyaltyInfo() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Check default royalty info
    (address receiver, uint256 royaltyAmount) = deployedNFT.royaltyInfo(1, 1000);
    assertEq(receiver, CREATOR);
    assertEq(royaltyAmount, 100); // 10% of 1000

    // Update royalty receiver for token
    deployedNFT.setRoyaltyReceiverForToken(ROYALTY_RECEIVER, 1);

    // Check updated royalty info
    (address updatedReceiver, ) = deployedNFT.royaltyInfo(1, 1000);
    assertEq(updatedReceiver, ROYALTY_RECEIVER);

    vm.stopPrank();
  }

  function test_RevertWhen_NonOwnerMints() public {
    vm.startPrank(USER1);

    // Try to mint as non-owner
    vm.expectRevert("Ownable: caller is not the owner");
    deployedNFT.addNewToken(TOKEN_URI);

    vm.stopPrank();
  }

  function test_RevertWhen_AttemptToUpdateLockedURI() public {
    vm.startPrank(CREATOR);

    // Add a new token
    deployedNFT.addNewToken(TOKEN_URI);

    // Lock token URIs
    deployedNFT.lockTokenURIs();

    // Try to update URI after locking
    vm.expectRevert("Token URIs are locked");
    deployedNFT.updateTokenURI(1, "ipfs://QmUpdated");

    vm.stopPrank();
  }

  function test_RevertWhen_MintingAfterDisabled() public {
    vm.startPrank(CREATOR);

    // Disable the contract
    deployedNFT.disableContract();

    // Try to mint after disabling
    vm.expectRevert("Contract must not be disabled.");
    deployedNFT.addNewToken(TOKEN_URI);

    vm.stopPrank();
  }

  function test_RevertWhen_ExceedMaxTokens() public {
    vm.startPrank(CREATOR);

    // Create a contract with small max tokens
    address newFactory = address(new SovereignNFTContractFactoryV2());
    SovereignNFTContractFactoryV2(newFactory).setSovereignNFT(address(sovereignNFT));

    address smallNFTAddr = SovereignNFTContractFactoryV2(newFactory).createSovereignNFTContract(
      "Limited",
      "LTD",
      2,
      SOVEREIGN_NFT
    );
    SovereignNFTV2 smallNFT = SovereignNFTV2(smallNFTAddr);

    // Mint up to the limit
    smallNFT.addNewToken("1");
    smallNFT.addNewToken("2");

    // Try to mint beyond the limit
    vm.expectRevert("_createToken::exceeded maxTokens");
    smallNFT.addNewToken("3");

    vm.stopPrank();
  }

  function test_BatchInfoRetrieval() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    deployedNFT.batchMint(BATCH_BASE_URI, 5);

    // Get batch info
    (uint256 startTokenId, uint256 endTokenId, string memory baseURI) = deployedNFT.getBatchInfo(0);

    // Verify batch info
    assertEq(startTokenId, 1);
    assertEq(endTokenId, 5);
    assertEq(baseURI, BATCH_BASE_URI);

    // Get batch count
    assertEq(deployedNFT.getBatchCount(), 1);

    vm.stopPrank();
  }

  function test_BatchBurnAndMinting() public {
    vm.startPrank(CREATOR);

    // Batch mint
    deployedNFT.batchMint(BATCH_BASE_URI, 5);

    // Burn a token from the batch
    deployedNFT.burn(3);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    deployedNFT.ownerOf(3);

    // Mint additional tokens
    deployedNFT.batchMint("https://second-batch.com/", 3);

    // Verify second batch
    (uint256 startTokenId, uint256 endTokenId, string memory baseURI) = deployedNFT.getBatchInfo(1);
    assertEq(startTokenId, 6);
    assertEq(endTokenId, 8);
    assertEq(baseURI, "https://second-batch.com/");

    vm.stopPrank();
  }

  function test_SupportsInterface() public {
    // Test interface support
    bytes4 erc721InterfaceId = 0x80ac58cd; // ERC721
    bytes4 erc2981InterfaceId = 0x2a55205a; // ERC2981

    assertTrue(deployedNFT.supportsInterface(erc721InterfaceId));
    assertTrue(deployedNFT.supportsInterface(erc2981InterfaceId));
  }
}
