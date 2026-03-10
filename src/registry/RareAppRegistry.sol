// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/// @title RareAppRegistry
/// @notice Registry for apps to register and set their own fee (in basis points).
/// @dev Protocol fee routing is handled by the Bazaar (networkBeneficiary); this contract calculates amounts only.
contract RareAppRegistry is Ownable {
  struct AppInfo {
    bool registered;
    uint16 feeBp; // app-chosen fee in basis points (0–10000)
    address feeRecipient; // where the app's share goes
  }

  mapping(address => AppInfo) public apps;

  // Protocol's share of every app fee, in bp of the app fee.
  // e.g., 2000 = protocol keeps 20% of the app's fee.
  uint16 public protocolShareBp = 2000;

  event AppRegistered(address indexed app, uint16 feeBp, address feeRecipient);
  event AppUpdated(address indexed app, uint16 feeBp, address feeRecipient);
  event AppDeregistered(address indexed app);
  event ProtocolShareUpdated(uint16 oldShare, uint16 newShare);

  constructor(address _owner) {
    _transferOwnership(_owner);
  }

  /// @notice Register the caller as an app with a fee
  function registerApp(uint16 _feeBp, address _feeRecipient) external {
    require(!apps[msg.sender].registered, "already registered");
    require(_feeRecipient != address(0), "zero address");
    apps[msg.sender] = AppInfo(true, _feeBp, _feeRecipient);
    emit AppRegistered(msg.sender, _feeBp, _feeRecipient);
  }

  /// @notice Update fee or recipient (app only)
  function updateApp(uint16 _feeBp, address _feeRecipient) external {
    require(apps[msg.sender].registered, "not registered");
    require(_feeRecipient != address(0), "zero address");
    apps[msg.sender].feeBp = _feeBp;
    apps[msg.sender].feeRecipient = _feeRecipient;
    emit AppUpdated(msg.sender, _feeBp, _feeRecipient);
  }

  /// @notice Deregister (app only)
  function deregisterApp() external {
    require(apps[msg.sender].registered, "not registered");
    delete apps[msg.sender];
    emit AppDeregistered(msg.sender);
  }

  /// @notice Calculate fee split for a given sale amount and app
  /// @return appShare amount going to the app's feeRecipient
  /// @return protocolShare amount going to the protocol
  /// @return totalFee appShare + protocolShare
  function calculateFeeSplit(address _app, uint256 _amount)
    external
    view
    returns (uint256 appShare, uint256 protocolShare, uint256 totalFee)
  {
    if (_app == address(0)) return (0, 0, 0);
    AppInfo memory info = apps[_app];
    if (!info.registered) return (0, 0, 0);

    totalFee = (_amount * info.feeBp) / 10000;
    protocolShare = (totalFee * protocolShareBp) / 10000;
    appShare = totalFee - protocolShare;
  }

  /// @notice Protocol admin: update the protocol's share of app fees
  function setProtocolShareBp(uint16 _shareBp) external onlyOwner {
    require(_shareBp <= 10000, "exceeds max");
    emit ProtocolShareUpdated(protocolShareBp, _shareBp);
    protocolShareBp = _shareBp;
  }
}
