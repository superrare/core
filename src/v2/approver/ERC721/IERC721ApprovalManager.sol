// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

/// @title IERC721ApprovalManager
/// @notice Interface for managing ERC721 token approvals and transfers
interface IERC721ApprovalManager {
  /// @notice Transfer an ERC721 token from a user to a recipient
  /// @param token The NFT contract address
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param tokenId The ID of the token to transfer
  function transferFrom(address token, address from, address to, uint256 tokenId) external;

  /// @notice Safely transfer an ERC721 token from a user to a recipient
  /// @param token The NFT contract address
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param tokenId The ID of the token to transfer
  /// @param data Additional data with no specified format
  function safeTransferFrom(address token, address from, address to, uint256 tokenId, bytes calldata data) external;

  /// @notice Safely transfer an ERC721 token from a user to a recipient without data
  /// @param token The NFT contract address
  /// @param from The address to transfer from
  /// @param to The recipient address
  /// @param tokenId The ID of the token to transfer
  function safeTransferFrom(address token, address from, address to, uint256 tokenId) external;
}
