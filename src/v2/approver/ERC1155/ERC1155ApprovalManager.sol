// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IERC1155ApprovalManager} from "./IERC1155ApprovalManager.sol";

/// @title ERC1155ApprovalManager
/// @notice A central approval manager for ERC1155 tokens that allows whitelisted contracts to transfer tokens.
/// @dev Users approve this manager on ERC1155 collections, and operator contracts execute transfers through it.
contract ERC1155ApprovalManager is IERC1155ApprovalManager, AccessControl {
    /// @notice Role for managing operators.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Role for contracts allowed to transfer tokens.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Whether the contract is disabled.
    bool public override disabled;

    /// @notice Grants deployer admin and manager roles.
    constructor() {
        // Role setup: deployer receives admin authority for AccessControl role administration.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Role setup: deployer receives explicit manager authority for this manager's admin methods.
        _grantRole(MANAGER_ROLE, msg.sender);

        // State write: initialize transfer execution as enabled.
        disabled = false;
    }

    /// @notice Modifier to check if contract is not disabled.
    modifier whenNotDisabled() {
        // Atomic guard: disabled managers reject transfer execution before external token calls.
        if (disabled) revert ContractDisabledError();
        _;
    }

    /// @inheritdoc IERC1155ApprovalManager
    function disable() external onlyRole(MANAGER_ROLE) {
        // State write: permanently disable future transfer execution.
        disabled = true;
        emit ContractDisabled(msg.sender);
    }

    /// @inheritdoc IERC1155ApprovalManager
    function grantOperatorRole(address operator) external onlyRole(MANAGER_ROLE) {
        // Role write: authorize one marketplace/operator contract to execute ERC1155 transfers.
        _grantRole(OPERATOR_ROLE, operator);
    }

    /// @inheritdoc IERC1155ApprovalManager
    function revokeOperatorRole(address operator) external onlyRole(MANAGER_ROLE) {
        // Role write: remove ERC1155 transfer authority from one operator contract.
        _revokeRole(OPERATOR_ROLE, operator);
    }

    /// @inheritdoc IERC1155ApprovalManager
    function batchGrantOperatorRole(address[] calldata operators) external onlyRole(MANAGER_ROLE) {
        for (uint256 i = 0; i < operators.length; i++) {
            // Role write: authorize the current operator address in the batch.
            _grantRole(OPERATOR_ROLE, operators[i]);
        }
    }

    /// @inheritdoc IERC1155ApprovalManager
    function batchRevokeOperatorRole(address[] calldata operators) external onlyRole(MANAGER_ROLE) {
        for (uint256 i = 0; i < operators.length; i++) {
            // Role write: revoke the current operator address in the batch.
            _revokeRole(OPERATOR_ROLE, operators[i]);
        }
    }

    /// @inheritdoc IERC1155ApprovalManager
    function safeTransferFrom(address token, address from, address to, uint256 id, uint256 amount, bytes calldata data)
        external
        whenNotDisabled
        onlyRole(OPERATOR_ROLE)
    {
        // External token call: token contract enforces holder approval, balance, and receiver acceptance.
        IERC1155 erc1155 = IERC1155(token);
        erc1155.safeTransferFrom(from, to, id, amount, data);
    }

    /// @inheritdoc IERC1155ApprovalManager
    function safeBatchTransferFrom(
        address token,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external whenNotDisabled onlyRole(OPERATOR_ROLE) {
        // External token call: token contract enforces holder approval, balances, and receiver acceptance.
        IERC1155 erc1155 = IERC1155(token);
        erc1155.safeBatchTransferFrom(from, to, ids, amounts, data);
    }
}
