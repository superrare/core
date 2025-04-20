// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @title IERC20ApprovalManager
/// @notice Interface for managing ERC20 token approvals and transfers
interface IERC20ApprovalManager {
  /// @notice Transfer ERC20 tokens from a user to a recipient
  /// @param token The token contract address
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param amount The amount of tokens to transfer
  function transferFrom(address token, address from, address to, uint256 amount) external;
}
