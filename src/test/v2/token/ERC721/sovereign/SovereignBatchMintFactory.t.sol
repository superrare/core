// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {SovereignBatchMint} from "../../../../../v2/token/ERC721/sovereign/SovereignBatchMint.sol";
import {SovereignBatchMintFactory} from "../../../../../v2/token/ERC721/sovereign/SovereignBatchMintFactory.sol";

contract SovereignBatchMintFactoryTest is Test {
  // Events to test
  event SovereignBatchMintCreated(address indexed contractAddress, address indexed owner);

  // Contracts
  SovereignBatchMintFactory public factory;

  // Test values and addresses
  string public constant NAME = "Sovereign NFT";
  string public constant SYMBOL = "SNFT";
  uint256 public constant MAX_TOKENS = 1000;
  address public constant CREATOR = address(0x1);
  address public constant NON_OWNER = address(0x2);

  function setUp() public {
    // Deploy factory
    vm.prank(CREATOR);
    factory = new SovereignBatchMintFactory();
  }

  function testInitialState() public {
    // Verify initial contract reference is set
    assertTrue(factory.sovereignNFT() != address(0));

    // Verify ownership
    assertEq(factory.owner(), CREATOR);
  }

  function testSetSovereignBatchMint() public {
    vm.startPrank(CREATOR);

    // Deploy a new sovereign batch mint implementation
    SovereignBatchMint newImplementation = new SovereignBatchMint();

    // Set it as the new implementation
    factory.setSovereignBatchMint(address(newImplementation));

    // Verify it was set
    assertEq(factory.sovereignNFT(), address(newImplementation));

    vm.stopPrank();
  }

  function testCreateSovereignBatchMint() public {
    vm.startPrank(CREATOR);

    // Expect the creation event
    vm.expectEmit(false, true, false, false);
    emit SovereignBatchMintCreated(address(0), CREATOR);

    // Create a new sovereign batch mint contract
    address nftAddr = factory.createSovereignBatchMint(NAME, SYMBOL, MAX_TOKENS);

    // Verify it's a valid address
    assertTrue(nftAddr != address(0));

    // Verify the contract is properly initialized
    SovereignBatchMint nft = SovereignBatchMint(nftAddr);
    assertEq(nft.name(), NAME);
    assertEq(nft.symbol(), SYMBOL);
    assertEq(nft.maxTokens(), MAX_TOKENS);
    assertEq(nft.owner(), CREATOR);

    vm.stopPrank();
  }

  function testCreateSovereignBatchMintWithUnlimitedTokens() public {
    vm.startPrank(CREATOR);

    // Expect the creation event
    vm.expectEmit(false, true, false, false);
    emit SovereignBatchMintCreated(address(0), CREATOR);

    // Create a new sovereign batch mint contract with unlimited tokens
    address nftAddr = factory.createSovereignBatchMint(NAME, SYMBOL);

    // Verify it's a valid address
    assertTrue(nftAddr != address(0));

    // Verify the contract is properly initialized with max uint256 tokens
    SovereignBatchMint nft = SovereignBatchMint(nftAddr);
    assertEq(nft.name(), NAME);
    assertEq(nft.symbol(), SYMBOL);
    assertEq(nft.maxTokens(), type(uint256).max);
    assertEq(nft.owner(), CREATOR);

    vm.stopPrank();
  }

  function testRevertWhenNonOwnerSetsSovereignBatchMint() public {
    vm.startPrank(NON_OWNER);

    // Deploy a new sovereign batch mint implementation
    SovereignBatchMint newImplementation = new SovereignBatchMint();

    // Try to set it as the new implementation (should revert)
    vm.expectRevert("Ownable: caller is not the owner");
    factory.setSovereignBatchMint(address(newImplementation));

    vm.stopPrank();
  }

  function testRevertWhenSettingZeroAddress() public {
    vm.startPrank(CREATOR);

    // Try to set zero address as implementation (should revert)
    vm.expectRevert();
    factory.setSovereignBatchMint(address(0));

    vm.stopPrank();
  }

  function testRevertWhenCreateContractWithZeroMaxTokens() public {
    vm.startPrank(CREATOR);

    // Try to create a contract with zero max tokens (should revert)
    vm.expectRevert("createSovereignNFTContract::_maxTokens cant be zero");
    factory.createSovereignBatchMint(NAME, SYMBOL, 0);

    vm.stopPrank();
  }
}
