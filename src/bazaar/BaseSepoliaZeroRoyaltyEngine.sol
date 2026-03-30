// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

/// @notice Minimal royalty engine used only for Base Sepolia deploys.
/// @dev Always returns empty royalty recipients and amounts.
contract BaseSepoliaZeroRoyaltyEngine is IRoyaltyEngineV1 {
  function getRoyalty(
    address,
    uint256,
    uint256
  ) external pure returns (address payable[] memory recipients, uint256[] memory amounts) {
    return (new address payable[](0), new uint256[](0));
  }

  function getRoyaltyView(
    address,
    uint256,
    uint256
  ) external pure returns (address payable[] memory recipients, uint256[] memory amounts) {
    return (new address payable[](0), new uint256[](0));
  }

  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IRoyaltyEngineV1).interfaceId || interfaceId == type(IERC165).interfaceId;
  }
}
