// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IRareStakingRegistry} from "./IRareStakingRegistry.sol";

/// @title EmptyRareStakingRegistry
/// @notice Placeholder staking registry that returns empty values for Bazaar integrations.
contract EmptyRareStakingRegistry is IRareStakingRegistry {
  error UnsupportedOperation();

  function increaseAmountStaked(address, address, uint256) external pure {
    revert UnsupportedOperation();
  }

  function decreaseAmountStaked(address, address, uint256) external pure {
    revert UnsupportedOperation();
  }

  function setStakingAddresses(address, address, address) external pure {
    revert UnsupportedOperation();
  }

  function setDefaultPayee(address) external pure {
    revert UnsupportedOperation();
  }

  function setDiscountPercentage(uint256) external pure {
    revert UnsupportedOperation();
  }

  function setDeflationaryPercentage(uint256) external pure {
    revert UnsupportedOperation();
  }

  function setPeriodLength(uint256) external pure {
    revert UnsupportedOperation();
  }

  function setReverseRegistrar(address) external pure {
    revert UnsupportedOperation();
  }

  function setResolver(address) external pure {
    revert UnsupportedOperation();
  }

  function setSwapPool(address, address) external pure {
    revert UnsupportedOperation();
  }

  function transferRareFrom(address, address, uint256) external pure {
    revert UnsupportedOperation();
  }

  function getDefaultPayee() external pure returns (address) {
    return address(0);
  }

  function getSwapPool(address) external pure returns (address) {
    return address(0);
  }

  function getRareAddress() external pure returns (address) {
    return address(0);
  }

  function getWethAddress() external pure returns (address) {
    return address(0);
  }

  function getDiscountPercentage() external pure returns (uint256) {
    return 0;
  }

  function getDeflationaryPercentage() external pure returns (uint256) {
    return 0;
  }

  function getPeriodLength() external pure returns (uint256) {
    return 0;
  }

  function getStakingInfoForUser(address) external pure returns (Info memory info) {
    return info;
  }

  function getStakingAddressForUser(address) external pure returns (address) {
    return address(0);
  }

  function getRewardAccumulatorAddressForUser(address) external pure returns (address) {
    return address(0);
  }

  function getTotalAmountStakedByUser(address) external pure returns (uint256) {
    return 0;
  }

  function getTotalAmountStakedOnUser(address) external pure returns (uint256) {
    return 0;
  }

  function getUsersForStakingAddresses(address[] calldata stakingAddrs) external pure returns (address[] memory users) {
    return new address[](stakingAddrs.length);
  }

  function STAKING_INFO_SETTER_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_STAT_SETTER_ADMIN_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_STAT_SETTER_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_CONFIG_SETTER_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }

  function ENS_SETTER_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }

  function SWAP_POOL_SETTER_ROLE() external pure returns (bytes32) {
    return bytes32(0);
  }
}
