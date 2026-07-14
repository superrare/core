// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {LazySovereignBatchMint} from "../../../../../v2/token/ERC721/sovereign/LazySovereignBatchMint.sol";

using {toString} for uint256;

function toString(uint256 value) pure returns (string memory) {
    if (value == 0) {
        return "0";
    }
    uint256 temp = value;
    uint256 digits;
    while (temp != 0) {
        digits++;
        temp /= 10;
    }
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
        digits -= 1;
        buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
        value /= 10;
    }
    return string(buffer);
}

contract LazySovereignBatchMintTest is Test {
  // Events to test
  event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
  event TokenURIUpdated(uint256 indexed tokenId, string newURI);
  event BatchBaseURIUpdated(uint256 indexed batchIndex, string newBaseURI);
  event TokenURIsLocked();
  event ContractDisabled(address indexed user);
  event CreatorSet(address indexed creator);
  event PrepareMint(uint256 indexed startTokenId, uint256 indexed endTokenId, string baseURI);

  // Contracts
  LazySovereignBatchMint public lazyNFT;

  // Test addresses
  address public constant CREATOR = address(0x1);
  address public constant USER1 = address(0x2);
  address public constant USER2 = address(0x3);
  address public constant ROYALTY_RECEIVER = address(0x4);

  // Test values
  string public constant NAME = "Lazy Sovereign NFT";
  string public constant SYMBOL = "LSNFT";
  uint256 public constant MAX_TOKENS = 1000;
  string public constant TOKEN_URI = "ipfs://QmExample";
  string public constant BATCH_BASE_URI = "https://api.example.com/metadata";

  function setUp() public {
    // Deploy and initialize the lazy sovereign NFT contract
    vm.startPrank(CREATOR);
    lazyNFT = new LazySovereignBatchMint();
    lazyNFT.init(NAME, SYMBOL, CREATOR, MAX_TOKENS);
    vm.stopPrank();
  }

  // ==================== INITIAL STATE TESTS ====================

  function test_InitialState() public {
    assertEq(lazyNFT.name(), NAME);
    assertEq(lazyNFT.symbol(), SYMBOL);
    assertEq(lazyNFT.owner(), CREATOR);
    assertEq(lazyNFT.maxTokens(), MAX_TOKENS);
    assertFalse(lazyNFT.disabled());
    assertFalse(lazyNFT.tokenURIsLocked());
    assertEq(lazyNFT.totalSupply(), 0);
  }



  // ==================== PREPAREMINT TESTS ====================

  function test_PrepareMint_DoesNotIncrementTotalSupply() public {
    vm.startPrank(CREATOR);

    // Perform prepareMint
    uint256 numTokens = 5;
    lazyNFT.prepareMint(BATCH_BASE_URI, numTokens);

    // KEY DIFFERENCE: totalSupply should remain 0 (tokens not minted yet)
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }

  function test_PrepareMint_EmitsPrepareMintEvent() public {
    vm.startPrank(CREATOR);

    // Expect PrepareMint event (not ConsecutiveTransfer)
    uint256 numTokens = 5;
    vm.expectEmit(true, true, true, true);
    emit PrepareMint(1, numTokens, BATCH_BASE_URI);
    lazyNFT.prepareMint(BATCH_BASE_URI, numTokens);

    vm.stopPrank();
  }

  function test_PrepareMint_ReservesTokenIds() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves token IDs
    uint256 numTokens = 5;
    lazyNFT.prepareMint(BATCH_BASE_URI, numTokens);

    // Verify batch info is stored
    (uint256 startTokenId, uint256 endTokenId, string memory baseURI) = lazyNFT.getBatchInfo(0);
    assertEq(startTokenId, 1);
    assertEq(endTokenId, 5);
    assertEq(baseURI, BATCH_BASE_URI);
    assertEq(lazyNFT.getBatchCount(), 1);

    vm.stopPrank();
  }

  function test_PrepareMint_MultipleBatches() public {
    vm.startPrank(CREATOR);

    // Create multiple batches
    lazyNFT.prepareMint("https://batch1.com/", 3);
    lazyNFT.prepareMint("https://batch2.com/", 2);
    lazyNFT.prepareMint("https://batch3.com/", 5);

    // Verify batches
    assertEq(lazyNFT.getBatchCount(), 3);
    assertEq(lazyNFT.totalSupply(), 0); // Still 0 - no tokens minted

    // Verify each batch info
    (uint256 start1, uint256 end1, ) = lazyNFT.getBatchInfo(0);
    assertEq(start1, 1);
    assertEq(end1, 3);

    (uint256 start2, uint256 end2, ) = lazyNFT.getBatchInfo(1);
    assertEq(start2, 4);
    assertEq(end2, 5);

    (uint256 start3, uint256 end3, ) = lazyNFT.getBatchInfo(2);
    assertEq(start3, 6);
    assertEq(end3, 10);

    vm.stopPrank();
  }

  function test_RevertWhen_PrepareMintExceedsMaxBatches() public {
    vm.startPrank(CREATOR);

    // Create MAX_BATCHES (100) batches successfully
    uint256 maxBatches = lazyNFT.MAX_BATCHES();
    for (uint256 i = 0; i < maxBatches; i++) {
      lazyNFT.prepareMint(BATCH_BASE_URI, 1);
    }

    // Verify we have exactly MAX_BATCHES
    assertEq(lazyNFT.getBatchCount(), maxBatches);

    // Attempt to create one more batch should fail
    vm.expectRevert("prepareMint::exceeded max batches");
    lazyNFT.prepareMint(BATCH_BASE_URI, 1);

    vm.stopPrank();
  }

  // ==================== OWNEROF TESTS ====================

  function test_OwnerOf_ReturnsOwnerForUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // KEY BEHAVIOR: ownerOf returns owner() for unminted lazy tokens
    assertEq(lazyNFT.ownerOf(1), CREATOR);
    assertEq(lazyNFT.ownerOf(3), CREATOR);
    assertEq(lazyNFT.ownerOf(5), CREATOR);

    vm.stopPrank();
  }

  function test_OwnerOf_ReturnsOwnerForMintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Approve USER1 to transfer (simulating marketplace)
    lazyNFT.setApprovalForAll(USER1, true);

    vm.stopPrank();

    // Transfer token 3 (this mints it)
    vm.startPrank(USER1);
    lazyNFT.transferFrom(CREATOR, USER2, 3);
    vm.stopPrank();

    // Now ownerOf should work
    assertEq(lazyNFT.ownerOf(3), USER2);
  }


  function test_OwnerOf_RevertsForBurnedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Cancel (burn) token 2
    lazyNFT.burn(2);

    // ownerOf should revert
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.ownerOf(2);

    vm.stopPrank();
  }

  function test_OwnerOf_RevertsForNonExistentToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint tokens 1-5
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Token 6 is not part of any batch
    vm.expectRevert("ERC721: invalid token ID");
    lazyNFT.ownerOf(6);

    // Token 999 doesn't exist
    vm.expectRevert("ERC721: invalid token ID");
    lazyNFT.ownerOf(999);

    vm.stopPrank();
  }

  // ==================== TRANSFER TESTS ====================

  function test_Transfer_IncrementsTotalSupplyOnFirstMint() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    assertEq(lazyNFT.totalSupply(), 0);

    // Transfer token (this mints it)
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    // KEY DIFFERENCE: totalSupply increments on first transfer
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();
  }

  function test_Transfer_MintsLazyTokenBeforeTransfer() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Transfer token (this mints it to sender first, then transfers)
    lazyNFT.transferFrom(CREATOR, USER1, 2);

    // Token is now owned by USER1
    assertEq(lazyNFT.ownerOf(2), USER1);

    vm.stopPrank();
  }


  function test_Transfer_MultipleLazyTokens() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    assertEq(lazyNFT.totalSupply(), 0);

    // Transfer multiple tokens
    lazyNFT.transferFrom(CREATOR, USER1, 1);
    assertEq(lazyNFT.totalSupply(), 1);

    lazyNFT.transferFrom(CREATOR, USER1, 3);
    assertEq(lazyNFT.totalSupply(), 2);

    lazyNFT.transferFrom(CREATOR, USER2, 5);
    assertEq(lazyNFT.totalSupply(), 3);

    // Verify ownership
    assertEq(lazyNFT.ownerOf(1), USER1);
    assertEq(lazyNFT.ownerOf(3), USER1);
    assertEq(lazyNFT.ownerOf(5), USER2);

    vm.stopPrank();
  }

  function test_Transfer_DoesNotIncrementSupplyForMintedTokens() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // First transfer mints and increments supply
    lazyNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();

    // Second transfer of same token does NOT increment supply
    vm.startPrank(USER1);
    lazyNFT.transferFrom(USER1, USER2, 2);
    assertEq(lazyNFT.totalSupply(), 1); // Still 1

    vm.stopPrank();
  }

  // ==================== GETAPPROVED TESTS ====================

  function test_GetApproved_RevertsForUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // KEY DIFFERENCE: getApproved reverts for unminted lazy tokens
    vm.expectRevert("ERC721: approved query for nonexistent token");
    lazyNFT.getApproved(3);

    vm.stopPrank();
  }

  function test_GetApproved_WorksForMintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Transfer to mint the token
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();

    // Now approve and getApproved should work
    vm.startPrank(USER1);
    lazyNFT.approve(USER2, 3);
    assertEq(lazyNFT.getApproved(3), USER2);

    vm.stopPrank();
  }


  function test_GetApproved_ClearedAfterTransfer() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Transfer to mint token 3
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();

    // Approve USER2
    vm.startPrank(USER1);
    lazyNFT.approve(USER2, 3);
    assertEq(lazyNFT.getApproved(3), USER2);

    // Transfer clears approval
    lazyNFT.transferFrom(USER1, USER2, 3);
    assertEq(lazyNFT.getApproved(3), address(0));

    vm.stopPrank();
  }

  // ==================== BURN TESTS ====================

  function test_Burn_OwnerCanCancelUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    assertEq(lazyNFT.totalSupply(), 0);

    // KEY DIFFERENCE: Owner can cancel unminted lazy token
    lazyNFT.burn(3);

    // totalSupply unchanged (token was never minted)
    assertEq(lazyNFT.totalSupply(), 0);

    // Token is now marked as burned/canceled
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.ownerOf(3);

    vm.stopPrank();
  }

  function test_Burn_NonOwnerCannotCancelUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    vm.stopPrank();

    // Non-owner cannot cancel unminted lazy token
    vm.startPrank(USER1);
    vm.expectRevert("burn::only owner can cancel unminted lazy token");
    lazyNFT.burn(3);

    vm.stopPrank();
  }

  function test_Burn_MintedLazyToken_DecrementsSupply() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Transfer to mint token 3
    lazyNFT.transferFrom(CREATOR, USER1, 3);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();

    // Burn minted lazy token decrements supply
    vm.startPrank(USER1);
    lazyNFT.burn(3);
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }


  function test_Burn_CanceledTokenCannotBeMinted() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Cancel token 3
    lazyNFT.burn(3);

    // Attempt to transfer (mint) canceled token should fail
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();
  }

  function test_Burn_MultipleUnmintedTokens() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    assertEq(lazyNFT.totalSupply(), 0);

    // Cancel multiple unminted tokens
    lazyNFT.burn(1);
    lazyNFT.burn(3);
    lazyNFT.burn(5);

    // totalSupply still 0
    assertEq(lazyNFT.totalSupply(), 0);

    // All canceled tokens revert
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.ownerOf(1);

    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.ownerOf(3);

    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.ownerOf(5);

    // Uncanceled tokens can still be transferred
    lazyNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(lazyNFT.ownerOf(2), USER1);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();
  }

  // ==================== TOTALSUPPLY TESTS ====================

  function test_TotalSupply_StartsAtZero() public {
    assertEq(lazyNFT.totalSupply(), 0);
  }

  function test_TotalSupply_ZeroAfterPrepareMint() public {
    vm.startPrank(CREATOR);

    // KEY DIFFERENCE: totalSupply remains 0 after prepareMint
    lazyNFT.prepareMint(BATCH_BASE_URI, 10);
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }

  function test_TotalSupply_IncrementsOnTransfer() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    assertEq(lazyNFT.totalSupply(), 0);

    // Each transfer increments supply
    lazyNFT.transferFrom(CREATOR, USER1, 1);
    assertEq(lazyNFT.totalSupply(), 1);

    lazyNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(lazyNFT.totalSupply(), 2);

    lazyNFT.transferFrom(CREATOR, USER1, 3);
    assertEq(lazyNFT.totalSupply(), 3);

    vm.stopPrank();
  }


  function test_TotalSupply_DecrementsOnBurn() public {
    vm.startPrank(CREATOR);

    // PrepareMint and mint some tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    lazyNFT.transferFrom(CREATOR, USER1, 1);
    lazyNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(lazyNFT.totalSupply(), 2);

    vm.stopPrank();

    // Burn decrements supply
    vm.startPrank(USER1);
    lazyNFT.burn(1);
    assertEq(lazyNFT.totalSupply(), 1);

    lazyNFT.burn(2);
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }

  function test_TotalSupply_MixedOperations() public {
    vm.startPrank(CREATOR);

    assertEq(lazyNFT.totalSupply(), 0);

    // PrepareMint (supply stays 0)
    lazyNFT.prepareMint(BATCH_BASE_URI, 3);
    assertEq(lazyNFT.totalSupply(), 0);

    // Transfer lazy token (supply increases)
    lazyNFT.transferFrom(CREATOR, USER1, 1);
    assertEq(lazyNFT.totalSupply(), 1);

    // Transfer another lazy token
    lazyNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(lazyNFT.totalSupply(), 2);

    // Cancel unminted lazy token (supply unchanged)
    lazyNFT.burn(3);
    assertEq(lazyNFT.totalSupply(), 2);

    vm.stopPrank();

    // Burn minted token (supply decreases)
    vm.startPrank(USER1);
    lazyNFT.burn(1);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();
  }

  // ==================== TOKENURI TESTS ====================

  function test_TokenURI_WorksForUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // KEY BEHAVIOR: tokenURI works for unminted tokens (for display purposes)
    string memory expectedURI = string(abi.encodePacked(BATCH_BASE_URI, "/", uint256(3).toString(), ".json"));
    assertEq(lazyNFT.tokenURI(3), expectedURI);

    vm.stopPrank();
  }

  function test_TokenURI_WorksForMintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Transfer to mint token
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    // tokenURI still works
    string memory expectedURI = string(abi.encodePacked(BATCH_BASE_URI, "/", uint256(3).toString(), ".json"));
    assertEq(lazyNFT.tokenURI(3), expectedURI);

    vm.stopPrank();
  }


  // ==================== INTEGRATION TESTS ====================

  function test_FullLazyMintingFlow() public {
    vm.startPrank(CREATOR);

    // 1. PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 10);
    assertEq(lazyNFT.totalSupply(), 0);

    // 2. Tokens have metadata and ownerOf returns owner for unminted tokens
    assertEq(lazyNFT.ownerOf(5), CREATOR);
    
    string memory uri = lazyNFT.tokenURI(5);
    assertTrue(bytes(uri).length > 0);

    // 3. Transfer mints the token
    lazyNFT.transferFrom(CREATOR, USER1, 5);
    assertEq(lazyNFT.totalSupply(), 1);
    assertEq(lazyNFT.ownerOf(5), USER1);

    vm.stopPrank();

    // 4. New owner can burn
    vm.startPrank(USER1);
    lazyNFT.burn(5);
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }

  function test_MarketplaceIntegration() public {
    vm.startPrank(CREATOR);

    // Creator prepares collection
    lazyNFT.prepareMint(BATCH_BASE_URI, 100);

    // Creator approves marketplace (USER1 simulates marketplace)
    lazyNFT.setApprovalForAll(USER1, true);

    vm.stopPrank();

    // Marketplace transfers token to buyer (USER2)
    vm.startPrank(USER1);
    lazyNFT.transferFrom(CREATOR, USER2, 42);

    // Verify purchase
    assertEq(lazyNFT.ownerOf(42), USER2);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();
  }

  function test_MultipleBatches() public {
    vm.startPrank(CREATOR);

    // Create multiple batches
    lazyNFT.prepareMint(BATCH_BASE_URI, 3); // tokens 1,2,3
    lazyNFT.prepareMint("https://batch2.com/", 2); // tokens 4,5

    // Unminted lazy tokens return owner
    assertEq(lazyNFT.ownerOf(2), CREATOR);

    // Transfer lazy token
    lazyNFT.transferFrom(CREATOR, USER1, 3);
    assertEq(lazyNFT.totalSupply(), 1);
    assertEq(lazyNFT.ownerOf(3), USER1);

    vm.stopPrank();
  }

  function test_PrepareMintThenTransferMultiple() public {
    vm.startPrank(CREATOR);

    // PrepareMint large batch
    lazyNFT.prepareMint(BATCH_BASE_URI, 50);
    assertEq(lazyNFT.totalSupply(), 0);

    // Transfer multiple tokens to different users
    lazyNFT.transferFrom(CREATOR, USER1, 5);
    lazyNFT.transferFrom(CREATOR, USER1, 10);
    lazyNFT.transferFrom(CREATOR, USER1, 15);
    lazyNFT.transferFrom(CREATOR, USER2, 20);
    lazyNFT.transferFrom(CREATOR, USER2, 25);

    assertEq(lazyNFT.totalSupply(), 5);
    assertEq(lazyNFT.ownerOf(5), USER1);
    assertEq(lazyNFT.ownerOf(10), USER1);
    assertEq(lazyNFT.ownerOf(15), USER1);
    assertEq(lazyNFT.ownerOf(20), USER2);
    assertEq(lazyNFT.ownerOf(25), USER2);

    vm.stopPrank();
  }

  function test_CancelThenPrepareAgain() public {
    vm.startPrank(CREATOR);

    // PrepareMint tokens 1-5
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Cancel some tokens
    lazyNFT.burn(2);
    lazyNFT.burn(4);

    // PrepareMint more tokens (6-10)
    lazyNFT.prepareMint("https://batch2.com/", 5);

    // Can transfer non-canceled tokens
    lazyNFT.transferFrom(CREATOR, USER1, 1);
    lazyNFT.transferFrom(CREATOR, USER1, 3);
    lazyNFT.transferFrom(CREATOR, USER1, 7);

    assertEq(lazyNFT.totalSupply(), 3);

    // Cannot transfer canceled tokens
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.transferFrom(CREATOR, USER1, 2);

    vm.stopPrank();
  }

  // ==================== EDGE CASES & REVERTS ====================

  function test_RevertWhen_TransferCanceledLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint and cancel
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);
    lazyNFT.burn(3);

    // Cannot transfer canceled token
    vm.expectRevert("ERC721::invalid token ID");
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();
  }

  function test_RevertWhen_NonOwnerTransfersUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint reserves tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    vm.stopPrank();

    // Non-owner cannot transfer unminted token (not approved)
    vm.startPrank(USER1);
    vm.expectRevert("ERC721: caller is not token owner or approved");
    lazyNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();
  }


  function test_SupportsInterface() public {
    // Test interface support
    bytes4 erc721InterfaceId = 0x80ac58cd; // ERC721
    bytes4 erc2981InterfaceId = 0x2a55205a; // ERC2981

    assertTrue(lazyNFT.supportsInterface(erc721InterfaceId));
    assertTrue(lazyNFT.supportsInterface(erc2981InterfaceId));
  }

  function test_RevertWhen_NonOwnerPreparesMint() public {
    vm.startPrank(USER1);

    // Non-owner cannot prepareMint
    vm.expectRevert("Ownable: caller is not the owner");
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    vm.stopPrank();
  }

  function test_RevertWhen_PrepareMintAfterDisabled() public {
    vm.startPrank(CREATOR);

    // Disable contract
    lazyNFT.disableContract();

    // Cannot prepareMint after disabled
    vm.expectRevert("Contract must not be disabled.");
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    vm.stopPrank();
  }

  function test_RevertWhen_PrepareMintExceedsMaxTokens() public {
    vm.startPrank(CREATOR);

    // Create contract with small limit
    LazySovereignBatchMint smallNFT = new LazySovereignBatchMint();
    smallNFT.init("Limited", "LTD", CREATOR, 5);

    // PrepareMint within limit should work
    smallNFT.prepareMint(BATCH_BASE_URI, 5);

    // PrepareMint beyond limit should fail
    vm.expectRevert("prepareMint::exceeded maxTokens");
    smallNFT.prepareMint(BATCH_BASE_URI, 1);

    vm.stopPrank();
  }

  function test_OperatorCanTransferUnmintedLazyToken() public {
    vm.startPrank(CREATOR);

    // PrepareMint tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 5);

    // Set USER1 as operator
    lazyNFT.setApprovalForAll(USER1, true);

    vm.stopPrank();

    // Operator can transfer unminted lazy token
    vm.startPrank(USER1);
    lazyNFT.transferFrom(CREATOR, USER2, 4);

    // Verify transfer worked
    assertEq(lazyNFT.ownerOf(4), USER2);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();
  }

  function test_TotalSupplyAfterBurningLazyTokens() public {
    vm.startPrank(CREATOR);

    // Create lazy tokens
    lazyNFT.prepareMint(BATCH_BASE_URI, 3); // tokens 1,2,3
    lazyNFT.transferFrom(CREATOR, USER1, 2); // mint lazy token 2

    assertEq(lazyNFT.totalSupply(), 1); // minted lazy token 2

    // Cancel unminted lazy token (supply unchanged)
    lazyNFT.burn(3);
    assertEq(lazyNFT.totalSupply(), 1);

    vm.stopPrank();

    // Burn minted lazy token
    vm.startPrank(USER1);
    lazyNFT.burn(2);
    assertEq(lazyNFT.totalSupply(), 0);

    vm.stopPrank();
  }
}
