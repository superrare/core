// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRareStakingRegistry} from "./IRareStakingRegistry.sol";

/// @title StakingRegistryStub
/// @notice Minimal stub implementing IRareStakingRegistry for deployments without full staking.
/// @dev All view functions return safe defaults; write functions revert.
///      Used by Bazaar (redirects staking fees to networkBeneficiary when getRewardAccumulatorAddressForUser returns address(0))
///      and RareMinter (works if setContractSellerStakingMinimum is never used).
contract StakingRegistryStub is IRareStakingRegistry {
  function increaseAmountStaked(address, address, uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function decreaseAmountStaked(address, address, uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setStakingAddresses(address, address, address) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setDefaultPayee(address) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setDiscountPercentage(uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setDeflationaryPercentage(uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setPeriodLength(uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setReverseRegistrar(address) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setResolver(address) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function setSwapPool(address, address) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function transferRareFrom(address, address, uint256) external pure override {
    revert("StakingRegistryStub: write disabled");
  }

  function getDefaultPayee() external pure override returns (address) {
    return address(0);
  }

  function getSwapPool(address) external pure override returns (address) {
    return address(0);
  }

  function getRareAddress() external pure override returns (address) {
    return address(0);
  }

  function getWethAddress() external pure override returns (address) {
    return address(0);
  }

  function getDiscountPercentage() external pure override returns (uint256) {
    return 0;
  }

  function getDeflationaryPercentage() external pure override returns (uint256) {
    return 0;
  }

  function getPeriodLength() external pure override returns (uint256) {
    return 0;
  }

  function getStakingInfoForUser(address) external pure override returns (Info memory) {
    return Info("", "", address(0), address(0));
  }

  function getStakingAddressForUser(address) external pure override returns (address) {
    return address(0);
  }

  function getRewardAccumulatorAddressForUser(address) external pure override returns (address) {
    return address(0);
  }

  function getTotalAmountStakedByUser(address) external pure override returns (uint256) {
    return 0;
  }

  function getTotalAmountStakedOnUser(address) external pure override returns (uint256) {
    return 0;
  }

  function getUsersForStakingAddresses(address[] calldata) external pure override returns (address[] memory) {
    return new address[](0);
  }

  function STAKING_INFO_SETTER_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_STAT_SETTER_ADMIN_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_STAT_SETTER_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }

  function STAKING_CONFIG_SETTER_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }

  function ENS_SETTER_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }

  function SWAP_POOL_SETTER_ROLE() external pure override returns (bytes32) {
    return bytes32(0);
  }
}
