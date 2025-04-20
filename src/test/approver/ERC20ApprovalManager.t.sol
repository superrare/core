// SPDX-License-Identifier: MIT
pragma solidity =0.8.18;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../utils/TestToken.sol";
import {ERC20ApprovalManager} from "../../approver/ERC20ApprovalManager.sol";

contract ERC20ApprovalManagerTest is Test {
  // Events to test
  event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
  event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

  // Constants
  bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
  bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

  // Contracts
  ERC20ApprovalManager public approvalManager;
  TestToken public token;

  // Test addresses
  address public constant ADMIN = address(0x1);
  address public constant OPERATOR = address(0x2);
  address public constant TOKEN_OWNER = address(0x3);
  address public constant TOKEN_RECIPIENT = address(0x4);
  uint256 public constant INITIAL_BALANCE = 1000 ether;
  uint256 public constant TRANSFER_AMOUNT = 100 ether;

  function setUp() public {
    // Deploy contracts
    vm.startPrank(ADMIN);
    approvalManager = new ERC20ApprovalManager();
    token = new TestToken();

    // Setup initial state
    token.mint(TOKEN_OWNER, INITIAL_BALANCE);
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
    token.approve(address(approvalManager), TRANSFER_AMOUNT);
    vm.stopPrank();

    vm.prank(OPERATOR);
    approvalManager.transferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TRANSFER_AMOUNT);

    assertEq(token.balanceOf(TOKEN_RECIPIENT), TRANSFER_AMOUNT);
    assertEq(token.balanceOf(TOKEN_OWNER), INITIAL_BALANCE - TRANSFER_AMOUNT);
  }

  function test_BatchTransferFrom() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    address[] memory recipients = new address[](2);
    recipients[0] = TOKEN_RECIPIENT;
    recipients[1] = address(0x5);

    uint256[] memory amounts = new uint256[](2);
    amounts[0] = TRANSFER_AMOUNT;
    amounts[1] = TRANSFER_AMOUNT;

    uint256 totalAmount = TRANSFER_AMOUNT * 2;

    vm.startPrank(TOKEN_OWNER);
    token.approve(address(approvalManager), totalAmount);
    vm.stopPrank();

    vm.prank(OPERATOR);
    approvalManager.batchTransferFrom(address(token), TOKEN_OWNER, recipients, amounts);

    assertEq(token.balanceOf(recipients[0]), amounts[0]);
    assertEq(token.balanceOf(recipients[1]), amounts[1]);
    assertEq(token.balanceOf(TOKEN_OWNER), INITIAL_BALANCE - totalAmount);
  }

  function test_TransferFromRevertsForNonOperator() public {
    vm.startPrank(TOKEN_OWNER);
    token.approve(address(approvalManager), TRANSFER_AMOUNT);
    vm.stopPrank();

    vm.prank(address(0x6)); // Non-operator address
    vm.expectRevert(ERC20ApprovalManager.NotOperator.selector);
    approvalManager.transferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TRANSFER_AMOUNT);
  }

  function test_TransferFromRevertsWhenNotApproved() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    // Note: Not approving the approval manager

    vm.prank(OPERATOR);
    vm.expectRevert("Insufficient allowance");
    approvalManager.transferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TRANSFER_AMOUNT);
  }

  function test_BatchTransferFromRevertsForInsufficientAllowance() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    address[] memory recipients = new address[](2);
    recipients[0] = TOKEN_RECIPIENT;
    recipients[1] = address(0x5);

    uint256[] memory amounts = new uint256[](2);
    amounts[0] = TRANSFER_AMOUNT;
    amounts[1] = TRANSFER_AMOUNT;

    vm.startPrank(TOKEN_OWNER);
    token.approve(address(approvalManager), TRANSFER_AMOUNT); // Only approve half of what's needed
    vm.stopPrank();

    vm.prank(OPERATOR);
    vm.expectRevert("Insufficient allowance");
    approvalManager.batchTransferFrom(address(token), TOKEN_OWNER, recipients, amounts);
  }

  function test_BatchTransferFromRevertsForLengthMismatch() public {
    vm.startPrank(ADMIN);
    approvalManager.grantOperatorRole(OPERATOR);
    vm.stopPrank();

    address[] memory recipients = new address[](2);
    recipients[0] = TOKEN_RECIPIENT;
    recipients[1] = address(0x5);

    uint256[] memory amounts = new uint256[](1);
    amounts[0] = TRANSFER_AMOUNT;

    vm.startPrank(TOKEN_OWNER);
    token.approve(address(approvalManager), TRANSFER_AMOUNT * 2);
    vm.stopPrank();

    vm.prank(OPERATOR);
    vm.expectRevert("Length mismatch");
    approvalManager.batchTransferFrom(address(token), TOKEN_OWNER, recipients, amounts);
  }

  function test_HasAllowance() public {
    vm.startPrank(TOKEN_OWNER);
    token.approve(address(approvalManager), TRANSFER_AMOUNT);
    vm.stopPrank();

    assertTrue(approvalManager.hasAllowance(address(token), TOKEN_OWNER, TRANSFER_AMOUNT));
    assertFalse(approvalManager.hasAllowance(address(token), TOKEN_OWNER, TRANSFER_AMOUNT + 1));
  }

  function test_OnlyManagerCanGrantRole() public {
    vm.prank(OPERATOR);
    vm.expectRevert(
      abi.encodePacked("AccessControl: account ", vm.toString(OPERATOR), " is missing role ", vm.toString(MANAGER_ROLE))
    );
    approvalManager.grantOperatorRole(address(0x6));
  }
}
