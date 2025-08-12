// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {SovereignBatchMint} from "../../../../../v2/token/ERC721/sovereign/SovereignBatchMint.sol";

contract SovereignBatchMintTest is Test {
  // Events to test
  event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
  event TokenURIUpdated(uint256 indexed tokenId, string newURI);
  event BatchBaseURIUpdated(uint256 indexed batchIndex, string newBaseURI);
  event TokenURIsLocked();
  event ContractDisabled(address indexed user);
  event CreatorSet(address indexed creator);
  event ConsecutiveTransfer(
    uint256 indexed fromTokenId,
    uint256 toTokenId,
    address indexed fromAddress,
    address indexed toAddress
  );

  // Contracts
  SovereignBatchMint public sovereignNFT;

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
    // Deploy and initialize the sovereign NFT contract
    vm.startPrank(CREATOR);
    sovereignNFT = new SovereignBatchMint();
    sovereignNFT.init(NAME, SYMBOL, CREATOR, MAX_TOKENS);
    vm.stopPrank();
  }

  function test_InitialState() public {
    assertEq(sovereignNFT.name(), NAME);
    assertEq(sovereignNFT.symbol(), SYMBOL);
    assertEq(sovereignNFT.owner(), CREATOR);
    assertEq(sovereignNFT.maxTokens(), MAX_TOKENS);
    assertFalse(sovereignNFT.disabled());
    assertFalse(sovereignNFT.tokenURIsLocked());
    assertEq(sovereignNFT.totalSupply(), 0);
  }

  function test_AddNewToken() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Verify token was created correctly
    assertEq(sovereignNFT.totalSupply(), 1);
    assertEq(sovereignNFT.ownerOf(1), CREATOR);
    assertEq(sovereignNFT.tokenURI(1), TOKEN_URI);

    vm.stopPrank();
  }

  function test_MintTo() public {
    vm.startPrank(CREATOR);

    // Mint a token to USER1
    sovereignNFT.mintTo(TOKEN_URI, USER1, ROYALTY_RECEIVER);

    // Verify token was minted correctly
    assertEq(sovereignNFT.totalSupply(), 1);
    assertEq(sovereignNFT.ownerOf(1), USER1);
    assertEq(sovereignNFT.tokenURI(1), TOKEN_URI);

    vm.stopPrank();
  }

  function test_BatchMint() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    vm.expectEmit(true, true, true, true);
    emit ConsecutiveTransfer(1, numTokens, address(0), CREATOR);
    sovereignNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Verify tokens were minted correctly
    assertEq(sovereignNFT.totalSupply(), numTokens);

    // Check ownership and URIs
    for (uint256 i = 1; i <= numTokens; i++) {
      assertEq(sovereignNFT.ownerOf(i), CREATOR);
      assertEq(sovereignNFT.tokenURI(i), string(abi.encodePacked(BATCH_BASE_URI, "/", vm.toString(i), ".json")));
    }

    vm.stopPrank();
  }

  function test_SingleMintAfterBatchMint() public {
    vm.startPrank(CREATOR);

    // Perform batch mint of 5 tokens (IDs 1-5)
    uint256 numTokens = 5;
    sovereignNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Verify batch mint worked correctly
    assertEq(sovereignNFT.totalSupply(), numTokens);

    // Now perform a single mint - should get token ID 6
    sovereignNFT.addNewToken(TOKEN_URI);

    // Verify the single mint got the expected token ID (endTokenId + 1)
    assertEq(sovereignNFT.totalSupply(), numTokens + 1);
    assertEq(sovereignNFT.ownerOf(6), CREATOR);
    assertEq(sovereignNFT.tokenURI(6), TOKEN_URI);

    vm.stopPrank();
  }

  function test_RevertWhen_ExceedMaxBatches() public {
    vm.startPrank(CREATOR);

    // Create MAX_BATCHES (100) batches successfully
    uint256 maxBatches = sovereignNFT.MAX_BATCHES();
    for (uint256 i = 0; i < maxBatches; i++) {
      sovereignNFT.batchMint(BATCH_BASE_URI, 1);
    }

    // Verify we have exactly MAX_BATCHES
    assertEq(sovereignNFT.getBatchCount(), maxBatches);

    // Attempt to create one more batch should fail
    vm.expectRevert("batchMint::exceeded max batches");
    sovereignNFT.batchMint(BATCH_BASE_URI, 1);

    vm.stopPrank();
  }

  function test_SilentBurnEmitsTransferEvent() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    sovereignNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Verify token 3 is owned by CREATOR but never actually minted
    assertEq(sovereignNFT.ownerOf(3), CREATOR);

    // Burn token 3 and expect Transfer event to be emitted
    vm.expectEmit(true, true, true, true);
    emit Transfer(CREATOR, address(0), 3);
    sovereignNFT.burn(3);

    vm.stopPrank();
  }

  function test_BurnClearsApprovals() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    sovereignNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Approve USER1 for token 3 (batch-minted, never transferred)
    sovereignNFT.approve(USER1, 3);
    assertEq(sovereignNFT.getApproved(3), USER1);

    // Burn token 3 - this should clear the approval
    sovereignNFT.burn(3);

    // Verify the approval was cleared (should revert since token doesn't exist)
    vm.expectRevert("ERC721: approved query for nonexistent token");
    sovereignNFT.getApproved(3);

    vm.stopPrank();
  }

  function test_RegularBurnClearsApprovals() public {
    vm.startPrank(CREATOR);

    // Add a regular (non-batch) token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Approve USER1 for token 1
    sovereignNFT.approve(USER1, 1);
    assertEq(sovereignNFT.getApproved(1), USER1);

    // Burn token 1 - this should clear the approval
    sovereignNFT.burn(1);

    // Verify the approval was cleared (should revert since token doesn't exist)
    vm.expectRevert("ERC721: approved query for nonexistent token");
    sovereignNFT.getApproved(1);

    vm.stopPrank();
  }

  function test_UpdateTokenURI() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Update the token URI
    string memory newURI = "ipfs://QmUpdated";
    vm.expectEmit(true, true, true, true);
    emit TokenURIUpdated(1, newURI);
    sovereignNFT.updateTokenURI(1, newURI);

    // Verify URI was updated
    assertEq(sovereignNFT.tokenURI(1), newURI);

    vm.stopPrank();
  }

  function test_UpdateBatchBaseURI() public {
    vm.startPrank(CREATOR);

    // Perform batch mint
    uint256 numTokens = 5;
    sovereignNFT.batchMint(BATCH_BASE_URI, numTokens);

    // Update the batch base URI
    string memory newBaseURI = "https://api.updated.com/metadata";
    vm.expectEmit(true, true, true, true);
    emit BatchBaseURIUpdated(0, newBaseURI);
    sovereignNFT.updateBatchBaseURI(0, newBaseURI);

    // Verify base URI was updated for all tokens in the batch
    for (uint256 i = 1; i <= numTokens; i++) {
      assertEq(sovereignNFT.tokenURI(i), string(abi.encodePacked(newBaseURI, "/", vm.toString(i), ".json")));
    }

    vm.stopPrank();
  }

  function test_LockTokenURIs() public {
    vm.startPrank(CREATOR);

    // Lock token URIs
    vm.expectEmit(true, true, true, true);
    emit TokenURIsLocked();
    sovereignNFT.lockTokenURIs();

    // Verify URIs are locked
    assertTrue(sovereignNFT.tokenURIsLocked());
    assertTrue(sovereignNFT.areTokenURIsLocked());

    vm.stopPrank();
  }

  function test_DisableContract() public {
    vm.startPrank(CREATOR);

    // Disable the contract
    vm.expectEmit(true, true, true, true);
    emit ContractDisabled(CREATOR);
    sovereignNFT.disableContract();

    // Verify contract is disabled
    assertTrue(sovereignNFT.disabled());

    vm.stopPrank();
  }

  function test_Burn() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Burn the token
    sovereignNFT.burn(1);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(1);

    vm.stopPrank();
  }

  function test_Transfer() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Transfer token to USER1
    sovereignNFT.transferFrom(CREATOR, USER1, 1);

    // Verify transfer worked
    assertEq(sovereignNFT.ownerOf(1), USER1);

    vm.stopPrank();
  }

  function test_RoyaltyInfo() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Check default royalty info
    (address receiver, uint256 royaltyAmount) = sovereignNFT.royaltyInfo(1, 1000);
    assertEq(receiver, CREATOR);
    assertEq(royaltyAmount, 100); // 10% of 1000

    // Update royalty receiver for token
    sovereignNFT.setRoyaltyReceiverForToken(ROYALTY_RECEIVER, 1);

    // Check updated royalty info
    (address updatedReceiver, ) = sovereignNFT.royaltyInfo(1, 1000);
    assertEq(updatedReceiver, ROYALTY_RECEIVER);

    vm.stopPrank();
  }

  function test_RevertWhen_NonOwnerMints() public {
    vm.startPrank(USER1);

    // Try to mint as non-owner
    vm.expectRevert("Ownable: caller is not the owner");
    sovereignNFT.addNewToken(TOKEN_URI);

    vm.stopPrank();
  }

  function test_RevertWhen_AttemptToUpdateLockedURI() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);

    // Lock token URIs
    sovereignNFT.lockTokenURIs();

    // Try to update URI after locking
    vm.expectRevert("Token URIs are locked");
    sovereignNFT.updateTokenURI(1, "ipfs://QmUpdated");

    vm.stopPrank();
  }

  function test_RevertWhen_MintingAfterDisabled() public {
    vm.startPrank(CREATOR);

    // Disable the contract
    sovereignNFT.disableContract();

    // Try to mint after disabling
    vm.expectRevert("Contract must not be disabled.");
    sovereignNFT.addNewToken(TOKEN_URI);

    vm.stopPrank();
  }

  function test_RevertWhen_ExceedMaxTokens() public {
    vm.startPrank(CREATOR);

    // Create a contract with small max tokens
    SovereignBatchMint smallNFT = new SovereignBatchMint();
    smallNFT.init("Limited", "LTD", CREATOR, 2);

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
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Get batch info
    (uint256 startTokenId, uint256 endTokenId, string memory baseURI) = sovereignNFT.getBatchInfo(0);

    // Verify batch info
    assertEq(startTokenId, 1);
    assertEq(endTokenId, 5);
    assertEq(baseURI, BATCH_BASE_URI);

    // Get batch count
    assertEq(sovereignNFT.getBatchCount(), 1);

    vm.stopPrank();
  }

  function test_BatchBurnAndMinting() public {
    vm.startPrank(CREATOR);

    // Batch mint
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Burn a token from the batch
    sovereignNFT.burn(3);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(3);

    // Mint additional tokens
    sovereignNFT.batchMint("https://second-batch.com/", 3);

    // Verify second batch
    (uint256 startTokenId, uint256 endTokenId, string memory baseURI) = sovereignNFT.getBatchInfo(1);
    assertEq(startTokenId, 6);
    assertEq(endTokenId, 8);
    assertEq(baseURI, "https://second-batch.com/");

    vm.stopPrank();
  }

  function test_OwnerOfRevertsForBurned_RegularToken() public {
    vm.startPrank(CREATOR);
    sovereignNFT.addNewToken(TOKEN_URI);
    sovereignNFT.burn(1);
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(1);
    vm.stopPrank();
  }

  function test_OwnerOfRevertsForBurned_BatchToken() public {
    vm.startPrank(CREATOR);
    sovereignNFT.batchMint(BATCH_BASE_URI, 3);
    sovereignNFT.burn(2);
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(2);
    vm.stopPrank();
  }

  function test_OwnerOfRevertsForNonExistentNonBatchToken() public {
    vm.startPrank(CREATOR);

    // Mint a batch for IDs 1..5
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Token 6 is not part of any batch and has not been minted
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(6);

    vm.stopPrank();
  }

  function test_SupportsInterface() public {
    // Test interface support
    bytes4 erc721InterfaceId = 0x80ac58cd; // ERC721
    bytes4 erc2981InterfaceId = 0x2a55205a; // ERC2981

    assertTrue(sovereignNFT.supportsInterface(erc721InterfaceId));
    assertTrue(sovereignNFT.supportsInterface(erc2981InterfaceId));
  }

  function test_TotalSupplyNeverShrinks() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);
    assertEq(sovereignNFT.totalSupply(), 5);

    // Mint a single token
    sovereignNFT.addNewToken(TOKEN_URI);
    assertEq(sovereignNFT.totalSupply(), 6);

    // Burn batch-minted token (silent burn)
    sovereignNFT.burn(3);
    // Total supply should not decrease - this confirms the auditor's finding
    assertEq(sovereignNFT.totalSupply(), 6);

    // Burn regular token
    sovereignNFT.burn(6);
    // Total supply should not decrease even for regular burns
    assertEq(sovereignNFT.totalSupply(), 6);

    vm.stopPrank();
  }

  function test_ApprovalResetAfterLazyFirstTransfer() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Approve USER1 for token 3 (batch-minted, never explicitly minted)
    sovereignNFT.approve(USER1, 3);
    assertEq(sovereignNFT.getApproved(3), USER1);

    // Transfer token 3 to USER2 (this triggers the lazy mint and clears approval)
    sovereignNFT.transferFrom(CREATOR, USER2, 3);

    // Verify approval was cleared
    assertEq(sovereignNFT.getApproved(3), address(0));
    assertEq(sovereignNFT.ownerOf(3), USER2);

    vm.stopPrank();
  }

  function test_UpdateBatchBaseURIFailsWhenLocked() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Lock token URIs
    sovereignNFT.lockTokenURIs();

    // Try to update batch base URI after locking - should revert
    vm.expectRevert("Token URIs are locked");
    sovereignNFT.updateBatchBaseURI(0, "https://locked-should-fail.com/");

    vm.stopPrank();
  }

  function test_TotalSupplyAfterVariousBurns() public {
    vm.startPrank(CREATOR);

    uint256 initialSupply = 0;
    assertEq(sovereignNFT.totalSupply(), initialSupply);

    // Batch mint 3 tokens (IDs 1, 2, 3)
    sovereignNFT.batchMint(BATCH_BASE_URI, 3);
    uint256 afterBatchMint = 3;
    assertEq(sovereignNFT.totalSupply(), afterBatchMint);

    // Add regular token (ID 4)
    sovereignNFT.addNewToken(TOKEN_URI);
    uint256 afterSingleMint = 4;
    assertEq(sovereignNFT.totalSupply(), afterSingleMint);

    // Burn batch-minted token 2 (silent burn)
    sovereignNFT.burn(2);
    assertEq(sovereignNFT.totalSupply(), afterSingleMint); // Should not decrease

    // Burn regular token 4
    sovereignNFT.burn(4);
    assertEq(sovereignNFT.totalSupply(), afterSingleMint); // Should not decrease

    // Add another token (ID 5)
    sovereignNFT.addNewToken("ipfs://final");
    uint256 afterFinalMint = 5;
    assertEq(sovereignNFT.totalSupply(), afterFinalMint);

    // Burn the final token
    sovereignNFT.burn(5);
    assertEq(sovereignNFT.totalSupply(), afterFinalMint); // Should still not decrease

    vm.stopPrank();
  }

  function test_ReTransferOfBurnedBatchToken() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Verify token 3 exists (batch-minted)
    assertEq(sovereignNFT.ownerOf(3), CREATOR);

    // Burn token 3 (silent burn)
    sovereignNFT.burn(3);

    // Attempt to transfer the burned token should fail
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.transferFrom(CREATOR, USER1, 3);

    vm.stopPrank();
  }

  function test_OperatorTransfersUnMintedBatchToken() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Set USER1 as operator for all tokens
    sovereignNFT.setApprovalForAll(USER1, true);

    vm.stopPrank();

    // Switch to USER1 (the operator)
    vm.startPrank(USER1);

    // Verify USER1 is approved as operator
    assertTrue(sovereignNFT.isApprovedForAll(CREATOR, USER1));

    // USER1 transfers token 4 from CREATOR to USER2
    // This should work via the lazy-mint path since token 4 was batch-minted but never explicitly transferred
    sovereignNFT.transferFrom(CREATOR, USER2, 4);

    // Verify the transfer worked
    assertEq(sovereignNFT.ownerOf(4), USER2);

    vm.stopPrank();
  }

  function test_OperatorCannotTransferBurnedBatchToken() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Set USER1 as operator for all tokens
    sovereignNFT.setApprovalForAll(USER1, true);

    // Burn token 2
    sovereignNFT.burn(2);

    vm.stopPrank();

    // Switch to USER1 (the operator)
    vm.startPrank(USER1);

    // Attempt to transfer the burned token should fail
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.transferFrom(CREATOR, USER2, 2);

    vm.stopPrank();
  }

  function test_BatchTokenApprovalBeforeAndAfterFirstTransfer() public {
    vm.startPrank(CREATOR);

    // Batch mint 5 tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 5);

    // Approve USER1 for token 5 (batch-minted, never transferred)
    sovereignNFT.approve(USER1, 5);
    assertEq(sovereignNFT.getApproved(5), USER1);

    // Transfer using the approval
    vm.stopPrank();
    vm.startPrank(USER1);
    sovereignNFT.transferFrom(CREATOR, USER1, 5);

    // Verify the transfer worked and approval was cleared
    assertEq(sovereignNFT.ownerOf(5), USER1);
    assertEq(sovereignNFT.getApproved(5), address(0));

    vm.stopPrank();
  }

  function test_TotalSupplyBehaviorEdgeCases() public {
    vm.startPrank(CREATOR);

    // Test with empty contract
    assertEq(sovereignNFT.totalSupply(), 0);

    // Single mint
    sovereignNFT.addNewToken(TOKEN_URI);
    assertEq(sovereignNFT.totalSupply(), 1);

    // Burn the only token
    sovereignNFT.burn(1);
    assertEq(sovereignNFT.totalSupply(), 1); // Should not decrease

    // Batch mint after burn
    sovereignNFT.batchMint(BATCH_BASE_URI, 3);
    assertEq(sovereignNFT.totalSupply(), 4);

    // Burn all batch tokens
    sovereignNFT.burn(2);
    sovereignNFT.burn(3);
    sovereignNFT.burn(4);
    assertEq(sovereignNFT.totalSupply(), 4); // Should remain the same

    vm.stopPrank();
  }

  function test_RevertWhen_NonOwnerAttemptsToBurnRegularToken() public {
    vm.startPrank(CREATOR);

    // Add a new token owned by CREATOR
    sovereignNFT.addNewToken(TOKEN_URI);
    assertEq(sovereignNFT.ownerOf(1), CREATOR);

    vm.stopPrank();

    // Switch to USER1 (non-owner) and attempt to burn
    vm.startPrank(USER1);
    vm.expectRevert("Must be owner of token.");
    sovereignNFT.burn(1);

    vm.stopPrank();

    // Verify token still exists and is owned by CREATOR
    assertEq(sovereignNFT.ownerOf(1), CREATOR);
  }

  function test_RevertWhen_NonOwnerAttemptsToBurnBatchToken() public {
    vm.startPrank(CREATOR);

    // Batch mint 3 tokens owned by CREATOR
    sovereignNFT.batchMint(BATCH_BASE_URI, 3);
    assertEq(sovereignNFT.ownerOf(2), CREATOR);

    vm.stopPrank();

    // Switch to USER1 (non-owner) and attempt to burn batch token
    vm.startPrank(USER1);
    vm.expectRevert("Must be owner of token.");
    sovereignNFT.burn(2);

    vm.stopPrank();

    // Verify token still exists and is owned by CREATOR
    assertEq(sovereignNFT.ownerOf(2), CREATOR);
  }

  function test_RevertWhen_ApprovedUserAttemptsToBurn() public {
    vm.startPrank(CREATOR);

    // Add a new token and approve USER1
    sovereignNFT.addNewToken(TOKEN_URI);
    sovereignNFT.approve(USER1, 1);
    assertEq(sovereignNFT.getApproved(1), USER1);

    vm.stopPrank();

    // Switch to USER1 (approved but not owner) and attempt to burn
    vm.startPrank(USER1);
    vm.expectRevert("Must be owner of token.");
    sovereignNFT.burn(1);

    vm.stopPrank();

    // Verify token still exists, is owned by CREATOR, and approval is still intact
    assertEq(sovereignNFT.ownerOf(1), CREATOR);
    assertEq(sovereignNFT.getApproved(1), USER1);
  }

  function test_RevertWhen_OperatorAttemptsToBurn() public {
    vm.startPrank(CREATOR);

    // Add a new token and set USER1 as operator for all tokens
    sovereignNFT.addNewToken(TOKEN_URI);
    sovereignNFT.setApprovalForAll(USER1, true);
    assertTrue(sovereignNFT.isApprovedForAll(CREATOR, USER1));

    vm.stopPrank();

    // Switch to USER1 (operator but not owner) and attempt to burn
    vm.startPrank(USER1);
    vm.expectRevert("Must be owner of token.");
    sovereignNFT.burn(1);

    vm.stopPrank();

    // Verify token still exists, is owned by CREATOR, and operator approval is still intact
    assertEq(sovereignNFT.ownerOf(1), CREATOR);
    assertTrue(sovereignNFT.isApprovedForAll(CREATOR, USER1));
  }

  function test_OwnerCanBurnAfterTransfer() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);
    assertEq(sovereignNFT.ownerOf(1), CREATOR);

    // Transfer token to USER1
    sovereignNFT.transferFrom(CREATOR, USER1, 1);
    assertEq(sovereignNFT.ownerOf(1), USER1);

    vm.stopPrank();

    // Now USER1 is the owner and should be able to burn
    vm.startPrank(USER1);
    sovereignNFT.burn(1);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(1);

    vm.stopPrank();
  }

  function test_OriginalOwnerCannotBurnAfterTransfer() public {
    vm.startPrank(CREATOR);

    // Add a new token
    sovereignNFT.addNewToken(TOKEN_URI);
    assertEq(sovereignNFT.ownerOf(1), CREATOR);

    // Transfer token to USER1
    sovereignNFT.transferFrom(CREATOR, USER1, 1);
    assertEq(sovereignNFT.ownerOf(1), USER1);

    // CREATOR is no longer the owner and should not be able to burn
    vm.expectRevert("Must be owner of token.");
    sovereignNFT.burn(1);

    vm.stopPrank();

    // Verify token still exists and is owned by USER1
    assertEq(sovereignNFT.ownerOf(1), USER1);
  }

  function test_BatchTokenOwnerCanBurnAfterTransfer() public {
    vm.startPrank(CREATOR);

    // Batch mint tokens
    sovereignNFT.batchMint(BATCH_BASE_URI, 3);
    assertEq(sovereignNFT.ownerOf(2), CREATOR);

    // Transfer token 2 to USER1
    sovereignNFT.transferFrom(CREATOR, USER1, 2);
    assertEq(sovereignNFT.ownerOf(2), USER1);

    vm.stopPrank();

    // Now USER1 is the owner and should be able to burn
    vm.startPrank(USER1);
    sovereignNFT.burn(2);

    // Verify token was burned
    vm.expectRevert("ERC721: invalid token ID");
    sovereignNFT.ownerOf(2);

    vm.stopPrank();
  }
}
