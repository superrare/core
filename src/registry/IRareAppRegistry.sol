// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IRareAppRegistry
/// @notice Interface for the RareAppRegistry contract
interface IRareAppRegistry {
  struct AppInfo {
    bool registered;
    uint16 feeBp;
    address feeRecipient;
  }

  /// @notice Get app info for an address
  function apps(address) external view returns (bool registered, uint16 feeBp, address feeRecipient);

  /// @notice Calculate fee split for a given sale amount and app
  /// @return appShare amount going to the app's feeRecipient
  /// @return protocolShare amount going to the protocol
  /// @return totalFee appShare + protocolShare
  function calculateFeeSplit(address _app, uint256 _amount)
    external
    view
    returns (uint256 appShare, uint256 protocolShare, uint256 totalFee);
}
