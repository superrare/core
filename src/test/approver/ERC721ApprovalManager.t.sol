// SPDX-License-Identifier: MIT
pragma solidity =0.8.18;

import {Test} from "forge-std/Test.sol";
import {TestNFT} from "../utils/TestNFT.sol";
import {ERC721ApprovalManager} from "../../approver/ERC721/ERC721ApprovalManager.sol";

contract ERC721ApprovalManagerTest is Test {
  // Events to test
  event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
  event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

  // Constants
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
  bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

  // Contracts
  ERC721ApprovalManager public approvalManager;
  TestNFT public nft;

  // Test addresses
  address public constant ADMIN = address(0x1);
  address public constant OPERATOR = address(0x2);
  address public constant TOKEN_OWNER = address(0x3);
  address public constant TOKEN_RECIPIENT = address(0x4);
  uint256 public constant TOKEN_ID = 0; // TestNFT starts counting from 0

  function setUp() public {
    // Deploy contracts
    vm.startPrank(ADMIN);
    approvalManager = new ERC721ApprovalManager();
    nft = new TestNFT();

    // Setup initial state
    uint256 tokenId = nft.mint(TOKEN_OWNER);
    assertEq(tokenId, TOKEN_ID);
    vm.stopPrank();
  }

  function test_InitialState() public {
    // Check roles
    assertTrue(approvalManager.hasRole(DEFAULT_ADMIN_ROLE, ADMIN));
    assertTrue(approvalManager.hasRole(MANAGER_ROLE, ADMIN));
    assertFalse(approvalManager.hasRole(OPERATOR_ROLE, OPERATOR));
  }

  function test_GrantOperatorRole() public {
    vm.startPrank(ADMIN);

    vm.expectEmit(true, true, true, true);
    emit RoleGranted(OPERATOR_ROLE, OPERATOR, ADMIN);

    approvalManager.grantOperatorRole(OPERATOR);
    assertTrue(approvalManager.hasRole(OPERATOR_ROLE, OPERATOR));

    vm.stopPrank();
  }

  function test_RevokeOperatorRole() public {
    vm.startPrank(ADMIN);

    approvalManager.grantOperatorRole(OPERATOR);
    assertTrue(approvalManager.hasRole(OPERATOR_ROLE, OPERATOR));

    vm.expectEmit(true, true, true, true);
    emit RoleRevoked(OPERATOR_ROLE, OPERATOR, ADMIN);

    approvalManager.revokeOperatorRole(OPERATOR);
    assertFalse(approvalManager.hasRole(OPERATOR_ROLE, OPERATOR));

    vm.stopPrank();
  }

  function test_BatchGrantOperatorRole() public {
    vm.startPrank(ADMIN);

    address[] memory operators = new address[](2);
    operators[0] = OPERATOR;
    operators[1] = address(0x5);

    approvalManager.batchGrantOperatorRole(operators);

    assertTrue(approvalManager.hasRole(OPERATOR_ROLE, operators[0]));
    assertTrue(approvalManager.hasRole(OPERATOR_ROLE, operators[1]));

    vm.stopPrank();
  }

  function test_BatchRevokeOperatorRole() public {
    vm.startPrank(ADMIN);

    address[] memory operators = new address[](2);
    operators[0] = OPERATOR;
    operators[1] = address(0x5);

    approvalManager.batchGrantOperatorRole(operators);
    approvalManager.batchRevokeOperatorRole(operators);

    assertFalse(approvalManager.hasRole(OPERATOR_ROLE, operators[0]));
    assertFalse(approvalManager.hasRole(OPERATOR_ROLE, operators[1]));

    vm.stopPrank();
  }

  function test_TransferFrom() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    vm.startPrank(TOKEN_OWNER);
    nft.setApprovalForAll(address(approvalManager), true);
    vm.stopPrank();

    vm.prank(OPERATOR);
    approvalManager.transferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID);

    assertEq(nft.ownerOf(TOKEN_ID), TOKEN_RECIPIENT);
  }

  function test_SafeTransferFrom() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    vm.startPrank(TOKEN_OWNER);
    nft.setApprovalForAll(address(approvalManager), true);
    vm.stopPrank();

    vm.prank(OPERATOR);
    approvalManager.safeTransferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, "");

    assertEq(nft.ownerOf(TOKEN_ID), TOKEN_RECIPIENT);
  }

  function test_TransferFromRevertsForNonOperator() public {
    vm.startPrank(TOKEN_OWNER);
    nft.setApprovalForAll(address(approvalManager), true);
    vm.stopPrank();

    vm.prank(address(0x6)); // Non-operator address
    vm.expectRevert(
      abi.encodePacked(
        "AccessControl: account ",
        vm.toString(address(0x6)),
        " is missing role ",
        vm.toString(OPERATOR_ROLE)
      )
    );
    approvalManager.transferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID);
  }

  function test_TransferFromRevertsWhenNotApproved() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    // Note: Not setting approval for the approval manager

    vm.prank(OPERATOR);
    vm.expectRevert("ERC721: caller is not token owner or approved");
    approvalManager.transferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID);
  }

  function test_OnlyManagerCanGrantRole() public {
    vm.prank(OPERATOR);
    vm.expectRevert(
      abi.encodePacked("AccessControl: account ", vm.toString(OPERATOR), " is missing role ", vm.toString(MANAGER_ROLE))
    );
    approvalManager.grantOperatorRole(address(0x6));
  }

  function test_TransferFrom_RevertsWhenDisabled() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    approvalManager.disable();
    vm.stopPrank();

    vm.startPrank(TOKEN_OWNER);
    nft.setApprovalForAll(address(approvalManager), true);
    vm.stopPrank();

    vm.prank(OPERATOR);
    vm.expectRevert(ERC721ApprovalManager.ContractDisabledError.selector);
    approvalManager.transferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID);
  }

  function test_SafeTransferFrom_RevertsWhenDisabled() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    approvalManager.disable();
    vm.stopPrank();

    vm.startPrank(TOKEN_OWNER);
    nft.setApprovalForAll(address(approvalManager), true);
    vm.stopPrank();

    vm.prank(OPERATOR);
    vm.expectRevert(ERC721ApprovalManager.ContractDisabledError.selector);
    approvalManager.safeTransferFrom(address(nft), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, "");
  }
}
