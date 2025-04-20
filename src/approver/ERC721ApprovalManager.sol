// SPDX-License-Identifier: MIT
pragma solidity =0.8.18;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ERC721ApprovalManager
/// @notice A central approval manager for ERC721 tokens that allows whitelisted contracts to transfer tokens
/// @dev Uses role-based access control for operator management
contract ERC721ApprovalManager is AccessControl {
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

  /// @notice Transfers an NFT from one address to another
  /// @dev Only operators can call this function
  /// @param token The NFT contract address
  /// @param from The current owner of the token
  /// @param to The recipient of the token
  /// @param tokenId The ID of the token to transfer
  function transferFrom(address token, address from, address to, uint256 tokenId) external {
    if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();

    IERC721 nft = IERC721(token);
    require(_isApprovedOrOwner(nft, from, tokenId), "Not approved");
    nft.transferFrom(from, to, tokenId);
  }

  /// @notice Safe transfers an NFT from one address to another
  /// @dev Only operators can call this function
  /// @param token The NFT contract address
  /// @param from The current owner of the token
  /// @param to The recipient of the token
  /// @param tokenId The ID of the token to transfer
  /// @param data Additional data with no specified format
  function safeTransferFrom(address token, address from, address to, uint256 tokenId, bytes calldata data) external {
    if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();

    IERC721 nft = IERC721(token);
    require(_isApprovedOrOwner(nft, from, tokenId), "Not approved");
    nft.safeTransferFrom(from, to, tokenId, data);
  }

  /// @notice Checks if this contract can transfer a specific token
  /// @param nft The NFT contract
  /// @param from The current owner of the token
  /// @param tokenId The ID of the token to check
  function _isApprovedOrOwner(IERC721 nft, address from, uint256 tokenId) internal view returns (bool) {
    return nft.isApprovedForAll(from, address(this)) || nft.getApproved(tokenId) == address(this);
  }
}
