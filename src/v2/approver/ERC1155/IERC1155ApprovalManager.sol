// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title IERC1155ApprovalManager
/// @notice Interface for managing ERC1155 token approvals and transfers.
interface IERC1155ApprovalManager {
    /// @notice Error thrown when caller is not a manager.
    /// @param caller The account that attempted a manager-only operation.
    error NotManager(address caller);

    /// @notice Error thrown when caller is not an operator.
    error NotOperator();

    /// @notice Error thrown when contract is disabled.
    error ContractDisabledError();

    /// @notice Event emitted when contract is disabled.
    /// @param disabler The manager that disabled the approval manager.
    event ContractDisabled(address indexed disabler);

    /// @notice Returns whether the approval manager is permanently disabled.
    /// @return True when token transfer execution is disabled.
    function disabled() external view returns (bool);

    /// @notice Disables token transfers through the approval manager permanently.
    /// @dev Callable by an account with the manager role.
    function disable() external;

    /// @notice Grants operator transfer permissions to a contract.
    /// @param operator The contract address to grant the role to.
    function grantOperatorRole(address operator) external;

    /// @notice Revokes operator transfer permissions from a contract.
    /// @param operator The contract address to revoke the role from.
    function revokeOperatorRole(address operator) external;

    /// @notice Grants operator transfer permissions to multiple contracts.
    /// @param operators Contract addresses to grant the role to.
    function batchGrantOperatorRole(address[] calldata operators) external;

    /// @notice Revokes operator transfer permissions from multiple contracts.
    /// @param operators Contract addresses to revoke the role from.
    function batchRevokeOperatorRole(address[] calldata operators) external;

    /// @notice Safely transfer ERC1155 tokens from a user to a recipient.
    /// @param token The ERC1155 token contract address.
    /// @param from The address to transfer from.
    /// @param to The recipient address.
    /// @param id The token id to transfer.
    /// @param amount The amount of tokens to transfer.
    /// @param data Additional data with no specified format.
    function safeTransferFrom(address token, address from, address to, uint256 id, uint256 amount, bytes calldata data)
        external;

    /// @notice Safely transfer a batch of ERC1155 tokens from a user to a recipient.
    /// @param token The ERC1155 token contract address.
    /// @param from The address to transfer from.
    /// @param to The recipient address.
    /// @param ids The token ids to transfer.
    /// @param amounts The amounts of each token id to transfer.
    /// @param data Additional data with no specified format.
    function safeBatchTransferFrom(
        address token,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}
