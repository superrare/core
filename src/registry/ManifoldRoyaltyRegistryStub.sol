// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {ERC165} from "openzeppelin-contracts/utils/introspection/ERC165.sol";
import {IRoyaltyRegistry} from "royalty-registry/IRoyaltyRegistry.sol";

/// @notice Minimal stub implementing IRoyaltyRegistry (Manifold) for RoyaltyEngineV1.
/// @dev Returns tokenAddress for getRoyaltyLookupAddress (no overrides). Used when full Manifold RoyaltyRegistry is not needed.
contract ManifoldRoyaltyRegistryStub is ERC165, IRoyaltyRegistry {
  function setRoyaltyLookupAddress(address, address) external pure override returns (bool) {
    return true;
  }

  function getRoyaltyLookupAddress(address tokenAddress) external pure override returns (address) {
    return tokenAddress;
  }

  function getOverrideLookupTokenAddress(address) external pure override returns (address) {
    return address(0);
  }

  function overrideAllowed(address) external pure override returns (bool) {
    return false;
  }

  function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
    return
      interfaceId == type(IRoyaltyRegistry).interfaceId ||
      super.supportsInterface(interfaceId);
  }
}
