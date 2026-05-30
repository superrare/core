// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";

import {ERC1155ApprovalManager} from "../../../v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {IERC1155ApprovalManager} from "../../../v2/approver/ERC1155/IERC1155ApprovalManager.sol";

contract TestERC1155 is ERC1155 {
    constructor() ERC1155("ipfs://test/{id}.json") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}

contract ERC1155ApprovalManagerTest is Test {
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    ERC1155ApprovalManager public approvalManager;
    TestERC1155 public token;

    address public constant ADMIN = address(0x1);
    address public constant OPERATOR = address(0x2);
    address public constant TOKEN_OWNER = address(0x3);
    address public constant TOKEN_RECIPIENT = address(0x4);
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant TRANSFER_AMOUNT = 5;

    function setUp() public {
        vm.startPrank(ADMIN);
        approvalManager = new ERC1155ApprovalManager();
        token = new TestERC1155();
        token.mint(TOKEN_OWNER, TOKEN_ID, 10);
        vm.stopPrank();
    }

    function test_InitialState() public {
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

    function test_SafeTransferFrom() public {
        vm.startPrank(ADMIN);
        approvalManager.grantOperatorRole(OPERATOR);
        vm.stopPrank();

        vm.startPrank(TOKEN_OWNER);
        token.setApprovalForAll(address(approvalManager), true);
        vm.stopPrank();

        vm.prank(OPERATOR);
        approvalManager.safeTransferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, TRANSFER_AMOUNT, "");

        assertEq(token.balanceOf(TOKEN_RECIPIENT, TOKEN_ID), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(TOKEN_OWNER, TOKEN_ID), 10 - TRANSFER_AMOUNT);
    }

    function test_SafeBatchTransferFrom() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = TOKEN_ID;
        ids[1] = 2;
        amounts[0] = 2;
        amounts[1] = 3;

        token.mint(TOKEN_OWNER, ids[1], amounts[1]);

        vm.startPrank(ADMIN);
        approvalManager.grantOperatorRole(OPERATOR);
        vm.stopPrank();

        vm.startPrank(TOKEN_OWNER);
        token.setApprovalForAll(address(approvalManager), true);
        vm.stopPrank();

        vm.prank(OPERATOR);
        approvalManager.safeBatchTransferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, ids, amounts, "");

        assertEq(token.balanceOf(TOKEN_RECIPIENT, ids[0]), amounts[0]);
        assertEq(token.balanceOf(TOKEN_RECIPIENT, ids[1]), amounts[1]);
    }

    function test_SafeTransferFromRevertsForNonOperator() public {
        vm.startPrank(TOKEN_OWNER);
        token.setApprovalForAll(address(approvalManager), true);
        vm.stopPrank();

        vm.prank(address(0x6));
        vm.expectRevert(IERC1155ApprovalManager.NotOperator.selector);
        approvalManager.safeTransferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, TRANSFER_AMOUNT, "");
    }

    function test_SafeTransferFromRevertsWhenNotApproved() public {
        vm.startPrank(ADMIN);
        approvalManager.grantOperatorRole(OPERATOR);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vm.expectRevert("ERC1155: caller is not token owner or approved");
        approvalManager.safeTransferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, TRANSFER_AMOUNT, "");
    }

    function test_OnlyManagerCanGrantRole() public {
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IERC1155ApprovalManager.NotManager.selector, OPERATOR));
        approvalManager.grantOperatorRole(address(0x6));
    }

    function test_SafeTransferFrom_RevertsWhenDisabled() public {
        vm.startPrank(ADMIN);
        approvalManager.grantOperatorRole(OPERATOR);
        approvalManager.disable();
        vm.stopPrank();

        vm.startPrank(TOKEN_OWNER);
        token.setApprovalForAll(address(approvalManager), true);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vm.expectRevert(IERC1155ApprovalManager.ContractDisabledError.selector);
        approvalManager.safeTransferFrom(address(token), TOKEN_OWNER, TOKEN_RECIPIENT, TOKEN_ID, TRANSFER_AMOUNT, "");
    }
}
