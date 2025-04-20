// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @title IERC20ApprovalManager
/// @notice Interface for managing ERC20 token approvals and transfers
interface IERC20ApprovalManager {
  /// @notice Transfer ERC20 tokens from a user to a recipient
  /// @param token The ERC20 token contract
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param amount The amount of tokens to transfer
  function transferFromUser(IERC20 token, address from, address to, uint256 amount) external;

  /// @notice Check if the manager has approval to transfer tokens
  /// @param token The ERC20 token contract
  /// @param owner The token owner
  /// @param amount The amount to check approval for
  /// @return bool True if manager has sufficient approval
  function hasApproval(IERC20 token, address owner, uint256 amount) external view returns (bool);
}
