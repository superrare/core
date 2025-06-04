// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {SovereignNFTV2} from "../../../../../v2/token/ERC721/sovereign/SovereignNFTV2.sol";
import {SovereignNFTContractFactoryV2} from "../../../../../v2/token/ERC721/sovereign/SovereignNFTContractFactoryV2.sol";
import {SovereignNFTRoyaltyGuardV2} from "../../../../../v2/token/ERC721/sovereign/extensions/SovereignNFTRoyaltyGuardV2.sol";
import {SovereignNFTRoyaltyGuardDeadmanTriggerV2} from "../../../../../v2/token/ERC721/sovereign/extensions/SovereignNFTRoyaltyGuardDeadmanTriggerV2.sol";

contract SovereignNFTContractFactoryV2Test is Test {
  // Events to test
  event SovereignNFTContractCreatedV2(
    address indexed contractAddress,
    address indexed owner,
    bytes32 indexed contractType
  );

  // Constants
  bytes32 public constant SOVEREIGN_NFT = keccak256("SOVEREIGN_NFT");
  bytes32 public constant ROYALTY_GUARD = keccak256("ROYALTY_GUARD");
  bytes32 public constant ROYALTY_GUARD_DEADMAN = keccak256("ROYALTY_GUARD_DEADMAN");
  bytes32 public constant LAZY_SOVEREIGN_NFT = keccak256("LAZY_SOVEREIGN_NFT");
  bytes32 public constant LAZY_ROYALTY_GUARD = keccak256("LAZY_ROYALTY_GUARD");
  bytes32 public constant LAZY_ROYALTY_GUARD_DEADMAN = keccak256("LAZY_ROYALTY_GUARD_DEADMAN");

  // Contracts
  SovereignNFTContractFactoryV2 public factory;

  // Test values and addresses
  string public constant NAME = "Sovereign NFT";
  string public constant SYMBOL = "SNFT";
  uint256 public constant MAX_TOKENS = 1000;
  address public constant CREATOR = address(0x1);
  address public constant NON_OWNER = address(0x2);

  function setUp() public {
    // Deploy factory
    vm.prank(CREATOR);
    factory = new SovereignNFTContractFactoryV2();
  }

  function test_InitialState() public {
    // Verify initial contract references are set
    assertTrue(factory.sovereignNFT() != address(0));
    assertTrue(factory.sovereignNFTRoyaltyGuard() != address(0));
    assertTrue(factory.sovereignNFTRoyaltyGuardDeadmanTrigger() != address(0));

    // Verify ownership
    assertEq(factory.owner(), CREATOR);
  }

  function test_SetSovereignNFT() public {
    vm.startPrank(CREATOR);

    // Deploy a new sovereign NFT implementation
    SovereignNFTV2 newImplementation = new SovereignNFTV2();

    // Set it as the new implementation
    factory.setSovereignNFT(address(newImplementation));

    // Verify it was set
    assertEq(factory.sovereignNFT(), address(newImplementation));

    vm.stopPrank();
  }

  function test_SetSovereignNFTWithType() public {
    vm.startPrank(CREATOR);

    // Deploy new implementations
    SovereignNFTV2 newNFT = new SovereignNFTV2();
    SovereignNFTRoyaltyGuardV2 newRG = new SovereignNFTRoyaltyGuardV2();
    SovereignNFTRoyaltyGuardDeadmanTriggerV2 newRGDT = new SovereignNFTRoyaltyGuardDeadmanTriggerV2();

    // Set each implementation
    factory.setSovereignNFT(address(newNFT), SOVEREIGN_NFT);
    factory.setSovereignNFT(address(newRG), ROYALTY_GUARD);
    factory.setSovereignNFT(address(newRGDT), ROYALTY_GUARD_DEADMAN);

    // Verify they were set correctly
    assertEq(factory.sovereignNFT(), address(newNFT));
    assertEq(factory.sovereignNFTRoyaltyGuard(), address(newRG));
    assertEq(factory.sovereignNFTRoyaltyGuardDeadmanTrigger(), address(newRGDT));

    vm.stopPrank();
  }

  function test_CreateSovereignNFTContract() public {
    vm.startPrank(CREATOR);

    // Create a new sovereign NFT contract
    address nftAddr = factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS);

    // Verify it's a valid address
    assertTrue(nftAddr != address(0));

    vm.stopPrank();
  }

  function test_CreateSovereignNFTContractWithUnlimitedTokens() public {
    vm.startPrank(CREATOR);

    // Create a new sovereign NFT contract with unlimited tokens
    address nftAddr = factory.createSovereignNFTContract(NAME, SYMBOL);

    // Verify it's a valid address
    assertTrue(nftAddr != address(0));

    vm.stopPrank();
  }

  function test_CreateSovereignNFTContractWithType() public {
    vm.startPrank(CREATOR);

    // Create different types of sovereign NFT contracts
    address sovereignAddr = factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS, SOVEREIGN_NFT);
    address royaltyGuardAddr = factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS, ROYALTY_GUARD);
    address deadmanAddr = factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS, ROYALTY_GUARD_DEADMAN);

    // Verify they're valid addresses
    assertTrue(sovereignAddr != address(0));
    assertTrue(royaltyGuardAddr != address(0));
    assertTrue(deadmanAddr != address(0));

    vm.stopPrank();
  }

  function test_RevertWhen_NonOwnerSetsSovereignNFT() public {
    vm.startPrank(NON_OWNER);

    // Deploy a new sovereign NFT implementation
    SovereignNFTV2 newImplementation = new SovereignNFTV2();

    // Try to set it as the new implementation (should revert)
    vm.expectRevert("Ownable: caller is not the owner");
    factory.setSovereignNFT(address(newImplementation));

    vm.stopPrank();
  }

  function test_RevertWhen_SettingZeroAddress() public {
    vm.startPrank(CREATOR);

    // Try to set zero address as implementation (should revert)
    vm.expectRevert();
    factory.setSovereignNFT(address(0));

    vm.stopPrank();
  }

  function test_RevertWhen_SettingInvalidContractType() public {
    vm.startPrank(CREATOR);

    // Create an invalid contract type
    bytes32 invalidType = keccak256("INVALID_TYPE");

    // Deploy a new sovereign NFT implementation
    SovereignNFTV2 newImplementation = new SovereignNFTV2();

    // Try to set it with invalid type (should revert)
    vm.expectRevert("setSovereignNFT::Unsupported _contractType.");
    factory.setSovereignNFT(address(newImplementation), invalidType);

    vm.stopPrank();
  }

  function test_RevertWhen_CreateContractWithZeroMaxTokens() public {
    vm.startPrank(CREATOR);

    // Try to create a contract with zero max tokens (should revert)
    vm.expectRevert("createSovereignNFTContract::_maxTokens cant be zero");
    factory.createSovereignNFTContract(NAME, SYMBOL, 0);

    vm.stopPrank();
  }

  function test_RevertWhen_CreateContractWithInvalidType() public {
    vm.startPrank(CREATOR);

    // Create an invalid contract type
    bytes32 invalidType = keccak256("INVALID_TYPE");

    // Try to create a contract with invalid type (should revert)
    vm.expectRevert("createSovereignNFTContract::_contractType unsupported contract type.");
    factory.createSovereignNFTContract(NAME, SYMBOL, MAX_TOKENS, invalidType);

    vm.stopPrank();
  }
}
