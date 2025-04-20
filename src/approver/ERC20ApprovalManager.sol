// SPDX-License-Identifier: MIT
pragma solidity =0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ERC20ApprovalManager
/// @notice A central approval manager for ERC20 tokens that allows whitelisted contracts to transfer tokens
/// @dev Uses role-based access control for operator management
contract ERC20ApprovalManager is AccessControl {
  using SafeERC20 for IERC20;

  /// @notice Role for managing operators
  bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
  /// @notice Role for contracts allowed to transfer tokens
  bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

  /// @notice Error thrown when caller is not an operator
  error NotOperator();

  constructor() {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(MANAGER_ROLE, msg.sender);
  }

  /// @notice Allows MANAGER_ROLE to grant OPERATOR_ROLE to a contract
  /// @param operator The contract address to grant the role to
  function grantOperatorRole(address operator) external onlyRole(MANAGER_ROLE) {
    _grantRole(OPERATOR_ROLE, operator);
  }

  /// @notice Allows MANAGER_ROLE to revoke OPERATOR_ROLE from a contract
  /// @param operator The contract address to revoke the role from
  function revokeOperatorRole(address operator) external onlyRole(MANAGER_ROLE) {
    _revokeRole(OPERATOR_ROLE, operator);
  }

  /// @notice Batch version of grantOperatorRole
  /// @param operators Array of contract addresses to grant the role to
  function batchGrantOperatorRole(address[] calldata operators) external onlyRole(MANAGER_ROLE) {
    for (uint256 i = 0; i < operators.length; i++) {
      _grantRole(OPERATOR_ROLE, operators[i]);
    }
  }

  /// @notice Batch version of revokeOperatorRole
  /// @param operators Array of contract addresses to revoke the role from
  function batchRevokeOperatorRole(address[] calldata operators) external onlyRole(MANAGER_ROLE) {
    for (uint256 i = 0; i < operators.length; i++) {
      _revokeRole(OPERATOR_ROLE, operators[i]);
    }
  }

  /// @notice Transfers tokens from one address to another
  /// @dev Only operators can call this function
  /// @param token The token contract address
  /// @param from The address to transfer from
  /// @param to The address to transfer to
  /// @param amount The amount of tokens to transfer
  function transferFrom(address token, address from, address to, uint256 amount) external {
    if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();

    IERC20 erc20 = IERC20(token);
    require(erc20.allowance(from, address(this)) >= amount, "Insufficient allowance");
    erc20.safeTransferFrom(from, to, amount);
  }

  /// @notice Batch transfers tokens from one address to multiple addresses
  /// @dev Only operators can call this function
  /// @param token The token contract address
  /// @param from The address to transfer from
  /// @param tos The addresses to transfer to
  /// @param amounts The amounts of tokens to transfer
  function batchTransferFrom(address token, address from, address[] calldata tos, uint256[] calldata amounts) external {
    if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();
    require(tos.length == amounts.length, "Length mismatch");

    IERC20 erc20 = IERC20(token);

    uint256 totalAmount = 0;
    for (uint256 i = 0; i < amounts.length; i++) {
      totalAmount += amounts[i];
    }

    require(erc20.allowance(from, address(this)) >= totalAmount, "Insufficient allowance");

    for (uint256 i = 0; i < tos.length; i++) {
      erc20.safeTransferFrom(from, tos[i], amounts[i]);
    }
  }

  /// @notice Checks if this contract has sufficient allowance
  /// @param token The token contract
  /// @param owner The token owner
  /// @param amount The amount to check
  /// @return True if allowance is sufficient
  function hasAllowance(address token, address owner, uint256 amount) external view returns (bool) {
    return IERC20(token).allowance(owner, address(this)) >= amount;
  }
}
