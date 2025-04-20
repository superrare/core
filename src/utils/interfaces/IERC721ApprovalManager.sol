// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

/// @title IERC721ApprovalManager
/// @notice Interface for managing ERC721 token approvals and transfers
interface IERC721ApprovalManager {
  /// @notice Transfer an ERC721 token from a user to a recipient
  /// @param token The ERC721 token contract
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param tokenId The ID of the token to transfer
  function transferFromUser(IERC721 token, address from, address to, uint256 tokenId) external;

  /// @notice Check if the manager has approval to transfer a token
  /// @param token The ERC721 token contract
  /// @param owner The token owner
  /// @param tokenId The token ID to check approval for
  /// @return bool True if manager has approval
  function hasApproval(IERC721 token, address owner, uint256 tokenId) external view returns (bool);
}
